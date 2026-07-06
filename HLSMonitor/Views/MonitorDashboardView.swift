//
//  MonitorDashboardView.swift
//  HLSMonitor
//
//  iPad dashboard: every monitor section visible at once in a scrollable
//  column (or two-column grid), instead of the phone's swipeable carousel.
//

import SwiftUI

struct MonitorDashboardView: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    /// Number of card columns: 1 for the landscape side panel, 2 for the
    /// wider panel below the browser in iPad portrait.
    var columns: Int = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                LivePulseHeader(monitor: monitor)

                if columns >= 2 {
                    // Streams gets its own column: its card grows much taller
                    // than the others (playlist URLs plus a row per variant),
                    // and in a row-paired grid that height would stretch
                    // whichever compact card shared its row.
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            compactCards
                        }
                        VStack(spacing: 12) {
                            StreamsCard(monitor: monitor)
                        }
                    }
                } else {
                    cards
                }
            }
            .padding()
        }
        .background(Color("PaperBackground"))
    }

    /// Single-column order: Streams ahead of the long Events feed so it
    /// isn't buried beneath 30 event rows.
    @ViewBuilder
    private var cards: some View {
        PlaybackCard(monitor: monitor)
        DownloadChartCard(monitor: monitor)
        DownloadMetricsRow(monitor: monitor)
        SegmentsCard(monitor: monitor)
        LoudnessCard(monitor: monitor)
        StreamsCard(monitor: monitor)
        EventsCard(monitor: monitor)
    }

    /// Everything except Streams, for the left column of the two-column grid.
    @ViewBuilder
    private var compactCards: some View {
        PlaybackCard(monitor: monitor)
        DownloadChartCard(monitor: monitor)
        DownloadMetricsRow(monitor: monitor)
        SegmentsCard(monitor: monitor)
        LoudnessCard(monitor: monitor)
        EventsCard(monitor: monitor)
    }
}

// MARK: - Streams card

/// Card listing detected manifests and their variants. Unlike the phone's
/// List-based tab, this renders inline so it can live in the dashboard scroll.
private struct StreamsCard: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Streams", systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.semibold))
            if monitor.streams.isEmpty {
                Text("Detected .m3u8 playlists and their quality levels will be listed here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.streams) { stream in
                    VStack(alignment: .leading, spacing: 6) {
                        StreamHeaderView(stream: stream)
                        ForEach(stream.variants) { variant in
                            VariantRow(variant: variant, isActive: variant.id == monitor.activeVariant?.id)
                        }
                    }
                    if stream.id != monitor.streams.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("PanelBackground"), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Events card

/// Card showing the most recent monitor events, newest first, so the latest
/// activity is glanceable without scrolling inside the card.
private struct EventsCard: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    private static let maxEvents = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Events", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.subheadline.weight(.semibold))
            if monitor.events.isEmpty {
                Text("Network and player events will stream in here as they happen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(monitor.events.suffix(Self.maxEvents).reversed())) { event in
                    EventRow(event: event)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("PanelBackground"), in: RoundedRectangle(cornerRadius: 14))
    }
}
