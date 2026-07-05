//
//  NativeAudioLoudnessTap.swift
//  HLSMonitor
//
//  Meters the app's own audio output via ReplayKit in-app capture. This is
//  the only supported way to reach WKWebView's media-process audio (native
//  HLS playback never enters the page's Web Audio graph), and it consumes
//  no extra bandwidth because it taps what is already playing. Video frames
//  are discarded and the microphone stays disabled; nothing is recorded.
//

import Foundation
import ReplayKit
import CoreMedia

final class NativeAudioLoudnessTap {

    private let queue = DispatchQueue(label: "com.kindlyops.hlsmonitor.loudness-tap")
    private let meter = LoudnessMeter()
    private var timer: Timer?

    /// Starts capture. `onLevels` fires ~4×/s on the main actor while active;
    /// `onStateChange` reports start/stop with an error message on failure.
    func start(
        onLevels: @escaping @MainActor (AudioLoudness) -> Void,
        onStateChange: @escaping @MainActor (Bool, String?) -> Void
    ) {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            Task { @MainActor in onStateChange(false, "Screen capture is not available on this device") }
            return
        }
        recorder.isMicrophoneEnabled = false
        recorder.startCapture(handler: { [weak self] sampleBuffer, type, error in
            guard error == nil, type == .audioApp, let self else { return }
            self.queue.async { self.ingest(sampleBuffer) }
        }, completionHandler: { [weak self] error in
            Task { @MainActor in
                if let error {
                    onStateChange(false, error.localizedDescription)
                    return
                }
                onStateChange(true, nil)
                self?.scheduleReporting(onLevels)
            }
        })
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        RPScreenRecorder.shared().stopCapture { _ in }
        queue.async { self.meter.reset() }
    }

    // MARK: - Internals

    @MainActor
    private func scheduleReporting(_ onLevels: @escaping @MainActor (AudioLoudness) -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                let levels = self.meter.levels
                Task { @MainActor in onLevels(levels) }
            }
        }
    }

    private func ingest(_ sampleBuffer: CMSampleBuffer) {
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
        meter.process(channels: channels, sampleRate: asbd.mSampleRate)
    }

    /// Converts the captured AudioBufferList (Float32 or Int16, interleaved
    /// or planar) into per-channel float arrays.
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
