//
//  MonitorPanelView.swift
//  HLSMonitor
//

import SwiftUI

struct MonitorPanelView: View {
    @ObservedObject var monitor: HLSMonitorViewModel
    @State private var selectedCard: Int = 0

    fileprivate enum Card: Int, CaseIterable {
        case live
        case download
        case loudness
        case streams
        case events

        var title: String {
            switch self {
            case .live: return "Live"
            case .download: return "Download"
            case .loudness: return "Loudness"
            case .streams: return "Streams"
            case .events: return "Events"
            }
        }

        var symbol: String {
            switch self {
            case .live: return "waveform.path.ecg"
            case .download: return "waveform.path.ecg.rectangle"
            case .loudness: return "speaker.wave.2"
            case .streams: return "list.bullet.rectangle"
            case .events: return "text.line.first.and.arrowtriangle.forward"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Compact live header always visible above the carousel.
            LivePulseHeader(monitor: monitor)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Swipeable carousel of monitor cards.
            TabView(selection: $selectedCard) {
                LiveStatsView(monitor: monitor)
                    .tag(Card.live.rawValue)
                DownloadGraphView(monitor: monitor)
                    .tag(Card.download.rawValue)
                LoudnessView(monitor: monitor)
                    .tag(Card.loudness.rawValue)
                StreamsListView(monitor: monitor)
                    .tag(Card.streams.rawValue)
                EventLogView(monitor: monitor)
                    .tag(Card.events.rawValue)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Custom pill page indicator with labels.
            PageIndicatorBar(selectedCard: $selectedCard)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Page indicator

/// The bottom pill row. Sits inside the window's safe area, so plain padding is
/// enough to keep the pills clear of the home indicator. It must not feed
/// geometry (e.g. safe-area insets) back into its own padding via @State — that
/// creates a layout feedback loop that hangs the app at launch.
private struct PageIndicatorBar: View {
    @Binding var selectedCard: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MonitorPanelView.Card.allCases, id: \.rawValue) { card in
                let isSelected = card.rawValue == selectedCard
                HStack(spacing: 5) {
                    Image(systemName: card.symbol)
                        .font(.caption2)
                    if isSelected {
                        Text(card.title)
                            .font(.caption2.weight(.semibold))
                            .transition(.opacity.combined(with: .scale))
                    }
                }
                .padding(.horizontal, isSelected ? 10 : 8)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground))
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .contentShape(Capsule())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.25)) { selectedCard = card.rawValue }
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: selectedCard)
    }
}

// MARK: - Live Stats

private struct LiveStatsView: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        ScrollView {
            if monitor.playback == nil && monitor.streams.isEmpty {
                EmptyStateView(
                    symbol: "waveform.badge.magnifyingglass",
                    title: "No stream detected",
                    message: "Navigate to a page with an HLS video player. Manifests and segments will appear here automatically."
                )
            } else {
                VStack(spacing: 10) {
                    PlaybackCard(monitor: monitor)
                    SegmentsCard(monitor: monitor)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Download Graph

private struct DownloadGraphView: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        ScrollView {
            if monitor.segments.recentSamples.isEmpty {
                EmptyStateView(
                    symbol: "chart.bar.xaxis",
                    title: "No downloads yet",
                    message: "Segment download times will chart here as the player fetches media."
                )
            } else {
                VStack(spacing: 10) {
                    DownloadChartCard(monitor: monitor)
                    DownloadMetricsRow(monitor: monitor)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - Loudness

private struct LoudnessView: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        ScrollView {
            // Always render the card: its empty state carries the button
            // that starts device-audio metering for native players.
            VStack(spacing: 10) {
                LoudnessCard(monitor: monitor)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Streams

private struct StreamsListView: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        if monitor.streams.isEmpty {
            ScrollView {
                EmptyStateView(
                    symbol: "list.bullet.rectangle",
                    title: "No manifests yet",
                    message: "Detected .m3u8 playlists and their quality levels will be listed here."
                )
            }
        } else {
            List {
                ForEach(monitor.streams) { stream in
                    Section {
                        StreamHeaderView(stream: stream)
                        ForEach(stream.variants) { variant in
                            VariantRow(variant: variant, isActive: variant.id == monitor.activeVariant?.id)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Events

private struct EventLogView: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        if monitor.events.isEmpty {
            ScrollView {
                EmptyStateView(
                    symbol: "text.line.first.and.arrowtriangle.forward",
                    title: "No events yet",
                    message: "Network and player events will stream in here as they happen."
                )
            }
        } else {
            ScrollViewReader { proxy in
                List(monitor.events) { event in
                    EventRow(event: event)
                        .id(event.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: monitor.events.count) {
                    if let last = monitor.events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
