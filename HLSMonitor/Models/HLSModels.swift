//
//  HLSModels.swift
//  HLSMonitor
//

import Foundation

// MARK: - Monitor Events

enum MonitorEventKind: String {
    case manifest
    case segment
    case playback
    case quality
    case error
    case info

    var symbol: String {
        switch self {
        case .manifest: return "doc.text"
        case .segment: return "square.stack.3d.down.right"
        case .playback: return "play.circle"
        case .quality: return "arrow.up.arrow.down"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        }
    }
}

struct MonitorEvent: Identifiable {
    let id = UUID()
    let date: Date
    let kind: MonitorEventKind
    let title: String
    let detail: String

    init(kind: MonitorEventKind, title: String, detail: String = "") {
        self.date = Date()
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

// MARK: - HLS Stream Structures

struct HLSVariant: Identifiable, Hashable {
    let id = UUID()
    let bandwidth: Int
    let resolution: String?
    let height: Int?
    let codecs: String?
    let frameRate: Double?
    let uri: String

    var bandwidthMbps: String {
        String(format: "%.2f Mbps", Double(bandwidth) / 1_000_000)
    }
}

struct HLSStream: Identifiable {
    let id = UUID()
    let url: URL
    var isMaster: Bool
    var variants: [HLSVariant]
    var targetDuration: Double?
    var segmentCount: Int
    var isLive: Bool
    var lastUpdated: Date
}

// MARK: - Playback Stats

struct PlaybackStats {
    var width: Int = 0
    var height: Int = 0
    var currentTime: Double = 0
    var bufferedSeconds: Double = 0
    var droppedFrames: Int = 0
    var totalFrames: Int = 0
    var paused: Bool = true

    var resolutionText: String {
        (width > 0 && height > 0) ? "\(width)×\(height)" : "—"
    }
}

// MARK: - Segment Tracking

struct SegmentTracker {
    var count: Int = 0
    var totalBytes: Int = 0
    var lastBitrateMbps: Double?
    var averageBitrateMbps: Double?
    var lastSegmentName: String?

    var totalBytesText: String {
        let mb = Double(totalBytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(totalBytes) / 1024)
    }
}
