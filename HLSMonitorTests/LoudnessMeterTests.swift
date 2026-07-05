//
//  LoudnessMeterTests.swift
//  HLSMonitorTests
//

import Foundation
import CoreMedia
import Testing
@testable import HLSMonitor

struct LoudnessMeterTests {

    private func sine(
        frequency: Double, amplitude: Double, seconds: Double, rate: Double
    ) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    @Test func emptyMeterReportsNothing() {
        let meter = LoudnessMeter()
        let levels = meter.levels
        #expect(levels.momentary == nil)
        #expect(levels.shortTerm == nil)
        #expect(levels.integrated == nil)
        #expect(levels.peakDbfs == nil)
    }

    @Test func silenceReportsNilLoudness() {
        let meter = LoudnessMeter()
        meter.process(channels: [[Float](repeating: 0, count: 48_000)], sampleRate: 48_000)
        let levels = meter.levels
        #expect(levels.momentary == nil)
        #expect(levels.integrated == nil)
        #expect(levels.peakDbfs == nil)
    }

    @Test func stereoSineMatchesReferenceLoudness() {
        // BS.1770 calibration: a 997 Hz full-scale sine in one channel reads
        // -3.01 LKFS, so a -20 dBFS sine reads -23.01 mono and -20.00 when
        // present in both stereo channels.
        let meter = LoudnessMeter()
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 48_000)
        meter.process(channels: [tone, tone], sampleRate: 48_000)
        let levels = meter.levels
        #expect(levels.peakDbfs != nil && abs(levels.peakDbfs! - -20.0) < 0.05)
        #expect(levels.momentary != nil && abs(levels.momentary! - -20.0) < 0.1)
        #expect(levels.shortTerm != nil && abs(levels.shortTerm! - -20.0) < 0.1)
        #expect(levels.integrated != nil && abs(levels.integrated! - -20.0) < 0.1)
    }

    @Test func monoSineReadsThreeLowerThanStereo() {
        let meter = LoudnessMeter()
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 48_000)
        meter.process(channels: [tone], sampleRate: 48_000)
        let mono = meter.levels.momentary
        #expect(mono != nil && abs(mono! - -23.01) < 0.1)
    }

    @Test func sampleRateChangesAgreeWithinTolerance() {
        let meter48 = LoudnessMeter()
        meter48.process(
            channels: [sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 48_000)],
            sampleRate: 48_000
        )
        let meter44 = LoudnessMeter()
        meter44.process(
            channels: [sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 44_100)],
            sampleRate: 44_100
        )
        let a = meter48.levels.shortTerm
        let b = meter44.levels.shortTerm
        #expect(a != nil && b != nil && abs(a! - b!) < 0.2)
    }

    @Test func gatingExcludesLongQuietPassages() {
        // 5s of tone then 20s of near-silence: an ungated mean would sink by
        // ~7 dB; the gated integrated value must stay near the tone.
        let meter = LoudnessMeter()
        let rate = 48_000.0
        meter.process(
            channels: [sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: rate)],
            sampleRate: rate
        )
        meter.process(
            channels: [sine(frequency: 997, amplitude: 0.0001, seconds: 20, rate: rate)],
            sampleRate: rate
        )
        let integrated = meter.levels.integrated
        #expect(integrated != nil && abs(integrated! - -23.01) < 1.0)
    }

    // MARK: - CMSampleBuffer ingestion

    /// Builds an interleaved-stereo Int16 PCM sample buffer like the ones
    /// ReplayKit capture delivers.
    private func int16SampleBuffer(
        tone: [Float], rate: Double, bigEndian: Bool
    ) -> CMSampleBuffer {
        var samples = [Int16]()
        samples.reserveCapacity(tone.count * 2)
        for value in tone {
            let scaled = Int16(max(-32768, min(32767, (value * 32767).rounded())))
            let stored = bigEndian ? scaled.bigEndian : scaled
            samples.append(stored)
            samples.append(stored)
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | (bigEndian ? kAudioFormatFlagIsBigEndian : 0),
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr)

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer
        ) == noErr)
        samples.withUnsafeBytes { raw in
            #expect(CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer!,
                offsetIntoDestination: 0, dataLength: byteCount
            ) == noErr)
        }

        var sampleBuffer: CMSampleBuffer?
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: blockBuffer!,
            formatDescription: formatDescription!, sampleCount: tone.count,
            presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr)
        return sampleBuffer!
    }

    @Test func bigEndianInt16SampleBufferMetersCorrectly() {
        // ReplayKit broadcast capture delivers big-endian Int16 PCM — the
        // format that read as silence/garbage before AVAudioConverter
        // ingestion. Same-signal-both-channels must read -20 LUFS.
        let meter = LoudnessMeter()
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 1, rate: 44_100)
        for chunk in stride(from: 0, to: tone.count, by: 22_050) {
            let end = min(chunk + 22_050, tone.count)
            let buffer = int16SampleBuffer(
                tone: Array(tone[chunk..<end]), rate: 44_100, bigEndian: true
            )
            meter.process(sampleBuffer: buffer)
        }
        #expect(meter.buffersConsumed == meter.buffersReceived)
        #expect(meter.buffersConsumed > 0)
        let momentary = meter.levels.momentary
        #expect(momentary != nil && abs(momentary! - -20.0) < 0.1)
    }

    @Test func nativeEndianInt16SampleBufferMatchesBigEndian() {
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 1, rate: 44_100)
        let bigMeter = LoudnessMeter()
        bigMeter.process(sampleBuffer: int16SampleBuffer(tone: tone, rate: 44_100, bigEndian: true))
        let littleMeter = LoudnessMeter()
        littleMeter.process(sampleBuffer: int16SampleBuffer(tone: tone, rate: 44_100, bigEndian: false))
        let a = bigMeter.levels.momentary
        let b = littleMeter.levels.momentary
        #expect(a != nil && b != nil && abs(a! - b!) < 0.01)
    }

    @Test func buffersSplitAcrossCallsMatchOneCall() {
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 4, rate: 48_000)
        let whole = LoudnessMeter()
        whole.process(channels: [tone], sampleRate: 48_000)
        let chunked = LoudnessMeter()
        for chunk in stride(from: 0, to: tone.count, by: 1_024) {
            let end = min(chunk + 1_024, tone.count)
            chunked.process(channels: [Array(tone[chunk..<end])], sampleRate: 48_000)
        }
        let a = whole.levels.shortTerm
        let b = chunked.levels.shortTerm
        #expect(a != nil && b != nil && abs(a! - b!) < 0.01)
    }
}
