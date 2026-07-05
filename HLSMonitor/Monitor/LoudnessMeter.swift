//
//  LoudnessMeter.swift
//  HLSMonitor
//
//  BS.1770-4 loudness measurement over deinterleaved float PCM, using the
//  exact K-weighting filter design from libebur128 (the reference
//  implementation behind ffmpeg's ebur128). Not thread-safe: confine each
//  instance to one queue.
//
//  Compiled into both the app and the LoudnessBroadcast extension, which
//  exchange levels through the shared app group.
//

import Foundation
import CoreMedia

/// K-weighted loudness measurements. Values are LUFS (peak is sample-peak
/// dBFS); nil means silence / not yet enough audio for that window.
struct AudioLoudness {
    var momentary: Double?
    var shortTerm: Double?
    var integrated: Double?
    var peakDbfs: Double?
    /// True when the player keeps audio where the page cannot meter it
    /// (WebKit's native pipeline or a third-party MSE player).
    var unavailable: Bool = false
}

/// App-group plumbing between the broadcast extension (writer) and the
/// app (reader).
enum SharedLoudness {
    static let appGroup = "group.com.kindlyops.HLSMonitor"
    static let levelsKey = "HLSMonitor.systemLoudness"

    static func encode(_ levels: AudioLoudness, at date: Date) -> [String: Double] {
        var payload: [String: Double] = ["timestamp": date.timeIntervalSince1970]
        payload["momentary"] = levels.momentary
        payload["shortTerm"] = levels.shortTerm
        payload["integrated"] = levels.integrated
        payload["peakDbfs"] = levels.peakDbfs
        return payload
    }

    /// Returns the stored levels and their write time, or nil if absent.
    static func decode(_ payload: [String: Double]) -> (levels: AudioLoudness, date: Date)? {
        guard let timestamp = payload["timestamp"] else { return nil }
        let levels = AudioLoudness(
            momentary: payload["momentary"],
            shortTerm: payload["shortTerm"],
            integrated: payload["integrated"],
            peakDbfs: payload["peakDbfs"]
        )
        return (levels, Date(timeIntervalSince1970: timestamp))
    }
}

final class LoudnessMeter {

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        // Direct form II transposed state.
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// 100ms analysis hop; momentary = 4 hops (400ms), short-term = 30 (3s).
    private static let shortTermHops = 30
    private static let momentaryHops = 4
    /// Cap the gating history at one hour of 100ms blocks.
    private static let maxGatingBlocks = 36_000

    private var sampleRate: Double = 0
    private var channelCount = 0
    private var shelf: [Biquad] = []
    private var highpass: [Biquad] = []

    private var hopSamples = 0
    private var samplesIntoHop = 0
    private var sumSquares = 0.0
    private var currentHopPeak = 0.0
    /// Rolling K-weighted mean squares per 100ms hop (3s window).
    private var hopMeanSquares: [Double] = []
    /// Rolling unweighted sample peak per hop (3s window).
    private var hopPeaks: [Double] = []
    /// 400ms momentary-block mean squares for integrated gating.
    private var blockMeanSquares: [Double] = []

    /// Feeds a buffer of deinterleaved per-channel samples. Reconfigures
    /// (dropping filter state, keeping loudness history) when the format
    /// changes mid-stream.
    func process(channels: [[Float]], sampleRate rate: Double) {
        guard rate > 0, let first = channels.first, !first.isEmpty else { return }
        if rate != sampleRate || channels.count != channelCount {
            configure(rate: rate, channels: channels.count)
        }
        let frames = channels.map(\.count).min() ?? 0
        for frame in 0..<frames {
            var frameSquares = 0.0
            for channel in 0..<channelCount {
                let x = Double(channels[channel][frame])
                let magnitude = abs(x)
                if magnitude > currentHopPeak { currentHopPeak = magnitude }
                let weighted = highpass[channel].process(shelf[channel].process(x))
                frameSquares += weighted * weighted
            }
            sumSquares += frameSquares
            samplesIntoHop += 1
            if samplesIntoHop >= hopSamples {
                completeHop()
            }
        }
    }

    /// Current levels; nil fields mean silence or not yet a full window.
    var levels: AudioLoudness {
        AudioLoudness(
            momentary: Self.lufs(meanTail(Self.momentaryHops)),
            shortTerm: Self.lufs(meanTail(Self.shortTermHops)),
            integrated: integratedLufs(),
            peakDbfs: hopPeaks.max().flatMap { $0 > 0 ? 20 * log10($0) : nil }
        )
    }

    func reset() {
        sampleRate = 0
        channelCount = 0
        hopMeanSquares.removeAll()
        hopPeaks.removeAll()
        blockMeanSquares.removeAll()
        sumSquares = 0
        samplesIntoHop = 0
        currentHopPeak = 0
    }

    // MARK: - Internals

    private func configure(rate: Double, channels: Int) {
        sampleRate = rate
        channelCount = channels
        hopSamples = Int((rate / 10).rounded())
        samplesIntoHop = 0
        sumSquares = 0
        let design = Self.kWeightingDesign(rate: rate)
        shelf = Array(repeating: design.shelf, count: channels)
        highpass = Array(repeating: design.highpass, count: channels)
    }

    private func completeHop() {
        hopMeanSquares.append(sumSquares / Double(hopSamples))
        if hopMeanSquares.count > Self.shortTermHops { hopMeanSquares.removeFirst() }
        hopPeaks.append(currentHopPeak)
        if hopPeaks.count > Self.shortTermHops { hopPeaks.removeFirst() }
        if hopMeanSquares.count >= Self.momentaryHops,
           blockMeanSquares.count < Self.maxGatingBlocks,
           let block = meanTail(Self.momentaryHops) {
            blockMeanSquares.append(block)
        }
        sumSquares = 0
        samplesIntoHop = 0
        currentHopPeak = 0
    }

    private func meanTail(_ count: Int) -> Double? {
        guard hopMeanSquares.count >= count else { return nil }
        return hopMeanSquares.suffix(count).reduce(0, +) / Double(count)
    }

    /// BS.1770 gating: absolute gate at -70 LUFS, then a relative gate
    /// 10 LU below the mean loudness of the surviving blocks.
    private func integratedLufs() -> Double? {
        let absGated = blockMeanSquares.filter { Self.lufs($0) ?? -Double.infinity > -70 }
        guard !absGated.isEmpty else { return nil }
        let absMean = absGated.reduce(0, +) / Double(absGated.count)
        guard let relThreshold = Self.lufs(absMean).map({ $0 - 10 }) else { return nil }
        let relGated = absGated.filter { Self.lufs($0) ?? -Double.infinity > relThreshold }
        guard !relGated.isEmpty else { return nil }
        return Self.lufs(relGated.reduce(0, +) / Double(relGated.count))
    }

    private static func lufs(_ meanSquare: Double?) -> Double? {
        guard let meanSquare, meanSquare > 0 else { return nil }
        return -0.691 + 10 * log10(meanSquare)
    }

    /// K-weighting per libebur128: pre-emphasis shelf, then the RLB
    /// high-pass whose numerator BS.1770 specifies unnormalized.
    private static func kWeightingDesign(rate: Double) -> (shelf: Biquad, highpass: Biquad) {
        var f0 = 1681.974450955533
        let gainDb = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / rate)
        let vh = pow(10.0, gainDb / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / rate)
        let den = 1 + k / q + k * k
        let highpass = Biquad(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: 2 * (k * k - 1) / den,
            a2: (1 - k / q + k * k) / den
        )
        return (shelf, highpass)
    }
}

// MARK: - CMSampleBuffer ingestion

extension LoudnessMeter {

    /// Feeds a captured audio sample buffer (e.g. from ReplayKit).
    func process(sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }

        let bufferList = AudioBufferList.allocate(maximumBuffers: 8)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 8),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let channels = Self.deinterleave(bufferList: bufferList, asbd: asbd)
        guard !channels.isEmpty else { return }
        process(channels: channels, sampleRate: asbd.mSampleRate)
    }

    /// Converts an AudioBufferList (Float32 or Int16, interleaved or planar)
    /// into per-channel float arrays.
    private static func deinterleave(
        bufferList: UnsafeMutableAudioBufferListPointer,
        asbd: AudioStreamBasicDescription
    ) -> [[Float]] {
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isPlanar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = Int(asbd.mBitsPerChannel) / 8
        guard bytesPerSample == (isFloat ? 4 : 2) else { return [] }

        func samples(in buffer: AudioBuffer) -> [Float] {
            guard let data = buffer.mData else { return [] }
            let count = Int(buffer.mDataByteSize) / bytesPerSample
            if isFloat {
                let floats = data.bindMemory(to: Float32.self, capacity: count)
                return (0..<count).map { floats[$0] }
            }
            let ints = data.bindMemory(to: Int16.self, capacity: count)
            return (0..<count).map { Float(ints[$0]) / 32768 }
        }

        if isPlanar {
            return bufferList.map { samples(in: $0) }
        }
        guard let buffer = bufferList.first else { return [] }
        let channelCount = max(Int(buffer.mNumberChannels), 1)
        let interleaved = samples(in: buffer)
        guard channelCount > 1 else { return [interleaved] }
        let frames = interleaved.count / channelCount
        var channels = Array(repeating: [Float](repeating: 0, count: frames), count: channelCount)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                channels[channel][frame] = interleaved[frame * channelCount + channel]
            }
        }
        return channels
    }
}
