//
//  MonitoringSession.swift
//  HLSMonitor
//
//  A finished (or snapshotted) monitoring session and the store that
//  accumulates them across the day for quality reports.
//

import Foundation

/// A timestamped quality incident within a session, for the report timeline.
struct QualityEvent: Codable {
    enum Kind: String, Codable {
        case failure
        case gap
        case stall
        case qualitySwitch
    }

    var date: Date
    var kind: Kind
}

/// A continuous span of wall-clock time that was actually monitored. A
/// consolidated session carries one per source session so the timeline can
/// show coverage gaps between them.
struct MonitoredSpan: Codable {
    var start: Date
    var end: Date
}

struct MonitoringSession: Codable, Identifiable {
    var id = UUID()
    var streamURL: String
    var startDate: Date
    var endDate: Date
    var segmentCount: Int
    var totalBytes: Int
    var failureCount: Int
    var gapCount: Int
    var stallCount: Int
    var qualitySwitchCount: Int
    var medianDownloadMs: Double?
    var p95DownloadMs: Double?
    var peakDownloadMs: Double?
    var averageBitrateMbps: Double?
    var isLive: Bool?
    var lastResolution: String?
    /// Number of raw sessions merged into this one (1 for an unconsolidated
    /// session).
    var consolidatedCount: Int = 1

    /// Timestamped incidents for the report timeline. Optional so sessions
    /// persisted before this field existed still decode.
    var qualityEvents: [QualityEvent]?
    /// Monitored spans; nil means the single span startDate...endDate.
    var spansOverride: [MonitoredSpan]?

    var events: [QualityEvent] { qualityEvents ?? [] }
    var spans: [MonitoredSpan] {
        spansOverride ?? [MonitoredSpan(start: startDate, end: endDate)]
    }

    var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    /// Merges same-URL sessions into one report row. Counts and bytes sum;
    /// duration sums the individual monitored spans (sessions may have gaps
    /// between them); the median is weighted by segment count while p95 and
    /// peak take the worst case, since raw samples are not retained.
    static func consolidate(_ sessions: [MonitoringSession]) -> MonitoringSession? {
        guard var merged = sessions.first else { return nil }
        guard sessions.count > 1 else { return merged }

        let monitoredSeconds = sessions.reduce(0.0) { $0 + $1.duration }
        merged.startDate = sessions.map(\.startDate).min() ?? merged.startDate
        // Encode "sum of monitored time" while keeping start/end meaningful:
        // endDate remains the latest session end; duration is carried by the
        // dedicated field below via startDate adjustment at render time.
        merged.endDate = sessions.map(\.endDate).max() ?? merged.endDate
        merged.segmentCount = sessions.reduce(0) { $0 + $1.segmentCount }
        merged.totalBytes = sessions.reduce(0) { $0 + $1.totalBytes }
        merged.failureCount = sessions.reduce(0) { $0 + $1.failureCount }
        merged.gapCount = sessions.reduce(0) { $0 + $1.gapCount }
        merged.stallCount = sessions.reduce(0) { $0 + $1.stallCount }
        merged.qualitySwitchCount = sessions.reduce(0) { $0 + $1.qualitySwitchCount }
        merged.consolidatedCount = sessions.count
        merged.monitoredSeconds = monitoredSeconds
        merged.qualityEvents = sessions.flatMap(\.events).sorted { $0.date < $1.date }
        merged.spansOverride = sessions
            .map { MonitoredSpan(start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }

        let weighted = sessions.filter { $0.medianDownloadMs != nil && $0.segmentCount > 0 }
        let totalWeight = weighted.reduce(0) { $0 + $1.segmentCount }
        if totalWeight > 0 {
            merged.medianDownloadMs = weighted.reduce(0.0) {
                $0 + ($1.medianDownloadMs ?? 0) * Double($1.segmentCount)
            } / Double(totalWeight)
        }
        merged.p95DownloadMs = sessions.compactMap(\.p95DownloadMs).max()
        merged.peakDownloadMs = sessions.compactMap(\.peakDownloadMs).max()
        let bitrateWeighted = sessions.filter { $0.averageBitrateMbps != nil && $0.segmentCount > 0 }
        let bitrateWeight = bitrateWeighted.reduce(0) { $0 + $1.segmentCount }
        if bitrateWeight > 0 {
            merged.averageBitrateMbps = bitrateWeighted.reduce(0.0) {
                $0 + ($1.averageBitrateMbps ?? 0) * Double($1.segmentCount)
            } / Double(bitrateWeight)
        }
        merged.isLive = sessions.compactMap(\.isLive).last
        merged.lastResolution = sessions.compactMap(\.lastResolution).last
        return merged
    }

    /// Total monitored time. For unconsolidated sessions this equals
    /// endDate − startDate; consolidation stores the sum of spans here.
    var monitoredSeconds: TimeInterval {
        get { monitoredSecondsOverride ?? duration }
        set { monitoredSecondsOverride = newValue }
    }
    /// Set only by consolidate(); nil means "derive from start/end".
    var monitoredSecondsOverride: TimeInterval?
}

extension MonitoringSession {
    /// Linearly interpolated percentile over raw values (matches the
    /// SegmentTracker window percentile, but over a whole session).
    static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = percentile * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }
}

/// JSON-file-backed store of recent sessions. Prunes entries older than
/// seven days on every save.
final class SessionStore {
    private let fileURL: URL
    private(set) var sessions: [MonitoringSession]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("monitoring-sessions.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([MonitoringSession].self, from: data) {
            sessions = decoded
        } else {
            sessions = []
        }
    }

    func append(_ session: MonitoringSession) {
        sessions.append(session)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        sessions.removeAll { $0.endDate < cutoff }
        save()
    }

    /// Sessions from the same calendar day monitoring the same stream URL,
    /// oldest first. Only these are eligible for consolidation together.
    func sessions(matching url: String, sameDayAs date: Date, calendar: Calendar = .current) -> [MonitoringSession] {
        sessions
            .filter { $0.streamURL == url && calendar.isDate($0.startDate, inSameDayAs: date) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
