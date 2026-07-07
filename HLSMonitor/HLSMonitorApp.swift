//
//  HLSMonitorApp.swift
//  HLSMonitor
//
//  Created by Neel Makhecha on 9/5/25.
//

import AVFAudio
import OSLog
import SwiftUI

@main
struct HLSMonitorApp: App {
    init() {
        // Long-form playback session: keeps stream audio audible with the
        // silent switch on and routes like a media app (AirPlay, external
        // displays) instead of the default ambient behavior.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            Logger(subsystem: "com.kindlyops.HLSMonitor", category: "audio")
                .error("Failed to set playback audio session category: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
