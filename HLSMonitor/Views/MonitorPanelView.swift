//
//  MonitorPanelView.swift
//  HLSMonitor
//

import SwiftUI

struct MonitorPanelView: View {
    @ObservedObject var monitor: HLSMonitorViewModel
    @State private var selectedCard: Int = 0

    private enum Card: Int, CaseIterable {
        case live
        case download
        case streams
        case events

        var title: String {
            switch self {
            case .live: return "Live"
            case .download: return "Download"
            case .streams: return "Streams"
            case .events: return "Events"
            }
        }

        var symbol: String {
            switch self {
            case .live: return "waveform.path.ecg"
            case .download: return "waveform.path.ecg.rectangle"
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
                StreamsListView(monitor: monitor)
                    .tag(Card.streams.rawValue)
                EventLogView(monitor: monitor)
                    .tag(Card.events.rawValue)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Custom pill page indicator with labels.
            HStack(spacing: 6) {
                ForEach(Card.allCases, id: \.rawValue) { card in
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
            .padding(.vertical, 10)
            .animation(.snappy(duration: 0.25), value: selectedCard)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Live Pulse Header

/// Compact always-visible strip: pulses on each new segment and counts time since last download.
private struct LivePulseHeader: View {
    @ObservedObject var monitor: HLSMonitorViewModel
    @State private var pulse = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            // Pulsing activity dot.
            ZStack {
                Circle()
                    .fill(pulseColor.opacity(0.25))
                    .frame(width: 26, height: 26)
                    .scaleEffect(pulse ? 1.5 : 0.8)
                    .opacity(pulse ? 0 : 0.9)
                Circle()
                    .fill(pulseColor)
                    .frame(width: 11, height: 11)
                    .shadow(color: pulseColor.opacity(0.6), radius: pulse ? 6 : 2)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                Text(monitor.segments.lastSegmentName ?? "Waiting for segments…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(lastSegmentAgo)
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(agoColor)
                    .contentTransition(.numericText())
                Text("since last")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .onReceive(ticker) { now = $0 }
        .onChange(of: monitor.segments.count) {
            withAnimation(.easeOut(duration: 0.55)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                pulse = false
            }
        }
    }

    private var pulseColor: Color {
        guard let date = monitor.segments.lastSegmentDate else { return Color(.systemGray3) }
        let gap = now.timeIntervalSince(date)
        if gap > 12 { return .orange }
        return .green
    }

    private var agoColor: Color {
        guard let date = monitor.segments.lastSegmentDate else { return .secondary }
        return now.timeIntervalSince(date) > 12 ? .orange : .primary
    }

    private var statusText: String {
        if monitor.segments.count == 0 { return "Monitoring" }
        return "\(monitor.segments.count) segments"
    }

    private var lastSegmentAgo: String {
        guard let date = monitor.segments.lastSegmentDate else { return "—" }
        let secs = Int(now.timeIntervalSince(date))
        if secs < 60 { return "\(secs)s" }
        return String(format: "%d:%02d", secs / 60, secs % 60)
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
                VStack(spacing: 12) {
                    graphCard
                    metricsRow
                }
                .padding()
                .padding(.bottom, 8)
            }
        }
    }

    private var graphCard: some View {
        let samples = monitor.segments.recentSamples
        let failures = monitor.segments.recentFailureMarkers
        let peak = max(samples.map(\.downloadMs).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Segment Download Time", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let last = monitor.segments.lastDownloadMs {
                    Text(String(format: "%.0f ms", last))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
            }

            GeometryReader { geo in
                LineChart(
                    values: samples.map(\.downloadMs),
                    failureIndices: failures.map(\.sampleIndex),
                    peak: peak,
                    size: geo.size
                )
                .animation(.easeOut(duration: 0.3), value: samples.count)
                .animation(.easeOut(duration: 0.3), value: failures.count)
            }
            .frame(height: 120)

            HStack(spacing: 10) {
                Text(String(format: "Peak %.0f ms · %d recent segments", peak, samples.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !failures.isEmpty {
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 2, height: 10)
                        Text("failed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var metricsRow: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(title: "Average", value: monitor.segments.averageDownloadMs.map { String(format: "%.0f ms", $0) } ?? "—")
            StatCard(title: "Peak", value: monitor.segments.peakDownloadMs.map { String(format: "%.0f ms", $0) } ?? "—",
                     color: (monitor.segments.peakDownloadMs ?? 0) > 2000 ? .orange : .primary)
            StatCard(title: "Failed", value: "\(monitor.segments.failureCount)",
                     color: monitor.segments.failureCount > 0 ? .red : .primary)
        }
    }

    private func barColor(for ms: Double, peak: Double) -> Color {
        if ms > 2000 { return .orange }
        if ms > peak * 0.75 { return .teal }
        return .accentColor
    }
}

// MARK: - Line Chart

/// Smooth line chart with a soft area fill and endpoint dot for download times.
private struct LineChart: View {
    let values: [Double]
    var failureIndices: [Int] = []
    let peak: Double
    let size: CGSize

    var body: some View {
        ZStack {
            // Baseline grid line
            Path { path in
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
            }
            .stroke(Color(.systemGray4).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Vertical marks for failed segment downloads (drawn behind the line).
            ForEach(failureXPositions, id: \.self) { x in
                ZStack {
                    Rectangle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 2)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .shadow(color: Color.red.opacity(0.6), radius: 3)
                        .position(x: 1, y: 2)
                }
                .frame(width: 2, height: size.height)
                .position(x: x, y: size.height / 2)
            }

            if points.count >= 2 {
                // Soft area fill under the line
                areaPath
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // The line itself
                linePath
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                // Endpoint marker
                if let last = points.last {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: Color.accentColor.opacity(0.6), radius: 4)
                        .position(last)
                }
            } else if let only = points.first {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .position(only)
            }
        }
    }

    /// X positions for failure marks, mapped onto the same horizontal scale as the samples.
    private var failureXPositions: [CGFloat] {
        guard size.width > 0 else { return [] }
        let count = values.count
        let stepX = count > 1 ? size.width / CGFloat(count - 1) : 0
        return failureIndices.map { rawIndex in
            let clamped = max(0, min(rawIndex, max(count - 1, 0)))
            if count <= 1 { return size.width / 2 }
            return CGFloat(clamped) * stepX
        }
    }

    /// Maps values to points inside the geometry, padding the top so the peak isn't clipped.
    private var points: [CGPoint] {
        guard !values.isEmpty else { return [] }
        let topInset: CGFloat = 6
        let usableHeight = max(size.height - topInset, 1)
        let stepX = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let ratio = CGFloat(value / peak)
            let x = values.count > 1 ? CGFloat(index) * stepX : size.width / 2
            let y = topInset + (1 - ratio) * usableHeight
            return CGPoint(x: x, y: y)
        }
    }

    private var linePath: Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private var areaPath: Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            path.addLine(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
                VStack(spacing: 12) {
                    playbackGrid
                    segmentCard
                }
                .padding()
            }
        }
    }

    private var playbackGrid: some View {
        let stats = monitor.playback ?? PlaybackStats()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Playback", systemImage: "play.tv")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if monitor.playback != nil {
                    StatusBadge(
                        text: stats.paused ? "PAUSED" : "PLAYING",
                        color: stats.paused ? .orange : .green
                    )
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatCell(title: "Resolution", value: stats.resolutionText)
                StatCell(title: "Buffer", value: String(format: "%.1fs", stats.bufferedSeconds),
                         color: stats.bufferedSeconds < 2 && monitor.playback != nil ? .orange : .primary)
                StatCell(title: "Position", value: timeString(stats.currentTime))
                StatCell(title: "Dropped", value: "\(stats.droppedFrames)",
                         color: stats.droppedFrames > 0 ? .orange : .primary)
                StatCell(title: "Frames", value: stats.totalFrames > 0 ? "\(stats.totalFrames)" : "—")
                StatCell(title: "Rendition", value: monitor.activeVariant.map { "\($0.height ?? 0)p" } ?? "—")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var segmentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Segments", systemImage: "square.stack.3d.down.right")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatCell(title: "Loaded", value: "\(monitor.segments.count)")
                StatCell(title: "Transferred", value: monitor.segments.count > 0 ? monitor.segments.totalBytesText : "—")
                StatCell(title: "Throughput",
                         value: monitor.segments.averageBitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "—")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
                        streamHeader(stream)
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

    private func streamHeader(_ stream: HLSStream) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: stream.isMaster ? "doc.text.magnifyingglass" : "doc.text")
                    .foregroundStyle(.tint)
                Text(stream.isMaster ? "Master Playlist" : "Media Playlist")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !stream.isMaster {
                    StatusBadge(text: stream.isLive ? "LIVE" : "VOD",
                                color: stream.isLive ? .red : .blue)
                }
            }
            Text(stream.url.absoluteString)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !stream.isMaster {
                Text("\(stream.segmentCount) segments" +
                     (stream.targetDuration.map { String(format: " · target %.0fs", $0) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct VariantRow: View {
    let variant: HLSVariant
    let isActive: Bool

    var body: some View {
        HStack {
            Circle()
                .fill(isActive ? Color.green : Color(.systemGray4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.resolution ?? "Audio / unknown")
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                if let codecs = variant.codecs {
                    Text(codecs)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(variant.bandwidthMbps)
                    .font(.subheadline.monospacedDigit())
                if let fps = variant.frameRate {
                    Text(String(format: "%.0f fps", fps))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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

private struct EventRow: View {
    let event: MonitorEvent

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.caption.weight(.medium))
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(Self.timeFormatter.string(from: event.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var color: Color {
        switch event.kind {
        case .manifest: return .blue
        case .segment: return .teal
        case .playback: return .green
        case .quality: return .purple
        case .error: return .red
        case .info: return .secondary
        }
    }
}

// MARK: - Shared bits

private struct StatCell: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 48)
        .frame(maxWidth: .infinity)
    }
}
