//
//  SampleHandler.swift
//  LoudnessBroadcast
//
//  System broadcast extension that meters device audio. iOS feeds it the
//  mixed audio of every app — including WKWebView's out-of-process media,
//  which no in-app tap can hear — as .audioApp sample buffers. Levels are
//  written to the shared app group for the HLSMonitor app to display.
//  Nothing is recorded or uploaded; buffers are metered and dropped.
//

import ReplayKit
import CoreMedia

final class SampleHandler: RPBroadcastSampleHandler {

    private let meter = LoudnessMeter()
    private let defaults = UserDefaults(suiteName: SharedLoudness.appGroup)
    private var lastWrite = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        meter.reset()
        defaults?.removeObject(forKey: SharedLoudness.levelsKey)
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        if sampleBufferType == .audioApp {
            meter.process(sampleBuffer: sampleBuffer)
        }
        // Heartbeat from video buffers too, so the app can tell "extension
        // alive but receiving no audio" from "extension not running".
        guard sampleBufferType == .audioApp || sampleBufferType == .video else { return }

        let now = Date()
        guard now.timeIntervalSince(lastWrite) >= 0.25 else { return }
        lastWrite = now
        let diagnostics = SharedLoudness.Diagnostics(
            buffersReceived: meter.buffersReceived,
            buffersConsumed: meter.buffersConsumed
        )
        defaults?.set(SharedLoudness.encode(meter.levels, diagnostics: diagnostics, at: now),
                      forKey: SharedLoudness.levelsKey)
    }

    override func broadcastFinished() {
        defaults?.removeObject(forKey: SharedLoudness.levelsKey)
    }
}
