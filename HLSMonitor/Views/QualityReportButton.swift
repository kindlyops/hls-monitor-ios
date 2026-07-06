//
//  QualityReportButton.swift
//  HLSMonitor
//
//  Prominent entry point for sharing a quality report, shown at the bottom
//  of the phone panel and as the last dashboard card. Always visible — even
//  before any data exists — so users learn the feature is there; the sheet's
//  empty state explains what to do when nothing is reportable yet.
//

import SwiftUI

struct QualityReportButton: View {
    @ObservedObject var monitor: HLSMonitorViewModel
    @State private var showReport = false

    var body: some View {
        Button {
            showReport = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Quality Report")
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(hasReportableData ? Color.accentColor : Color.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color("PanelBackground"), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showReport) {
            QualityReportSheet(monitor: monitor)
        }
    }

    private var hasReportableData: Bool {
        liveSession != nil || !todaysSessions.isEmpty
    }

    /// The in-progress session, when it has recorded anything.
    private var liveSession: (start: Date, segments: Int)? {
        guard let start = monitor.sessionStartDate, monitor.segments.count > 0 else { return nil }
        return (start, monitor.segments.count)
    }

    private var todaysSessions: [MonitoringSession] {
        monitor.sessionStore.sessions.filter {
            Calendar.current.isDate($0.startDate, inSameDayAs: Date())
        }
    }

    private var subtitle: String {
        if let live = liveSession {
            let segments = live.segments == 1 ? "1 segment" : "\(live.segments) segments"
            return "\(durationText(Date().timeIntervalSince(live.start))) monitored · \(segments)"
        }
        let stored = todaysSessions.count
        if stored > 0 {
            return stored == 1
                ? "1 session from today ready to share"
                : "\(stored) sessions from today ready to share"
        }
        return "Available after monitoring a stream"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }
}
