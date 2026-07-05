//
//  MonitorComponents.swift
//  HLSMonitor
//
//  Shared monitor cards and leaf components, used by both the phone's
//  swipeable carousel (MonitorPanelView) and the iPad dashboard
//  (MonitorDashboardView).
//

import SwiftUI

// MARK: - Live Pulse Header

/// Compact always-visible strip: pulses on each new segment and counts time since last download.
struct LivePulseHeader: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    /// One ripple cycle per downloaded segment: invisible at rest, appears
    /// snugly around the dot, then expands outward while fading away.
    private enum PulsePhase: CaseIterable {
        case idle
        case primed
        case ripple
    }

    var body: some View {
        // TimelineView redraws each second with the current date. A Timer
        // publisher stored on this struct would be recreated (and its countdown
        // reset) every time the monitor publishes, so it would never fire.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            header(now: timeline.date)
        }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 12) {
            // Activity dot that pulses once per downloaded segment.
            ZStack {
                Circle()
                    .fill(pulseColor(now: now).opacity(0.25))
                    .frame(width: 26, height: 26)
                    .phaseAnimator(PulsePhase.allCases, trigger: monitor.segments.count) { ring, phase in
                        ring
                            .scaleEffect(phase == .ripple ? 1.5 : 0.6)
                            .opacity(phase == .primed ? 0.9 : 0)
                    } animation: { phase in
                        switch phase {
                        case .primed: .easeOut(duration: 0.12)
                        case .ripple: .easeOut(duration: 0.5)
                        case .idle: .linear(duration: 0.05)
                        }
                    }
                Circle()
                    .fill(pulseColor(now: now))
                    .frame(width: 11, height: 11)
                    .shadow(color: pulseColor(now: now).opacity(0.6), radius: 2)
                    .phaseAnimator(PulsePhase.allCases, trigger: monitor.segments.count) { dot, phase in
                        dot.scaleEffect(phase == .primed ? 1.25 : 1.0)
                    } animation: { phase in
                        switch phase {
                        case .primed: .easeOut(duration: 0.12)
                        case .ripple: .easeOut(duration: 0.5)
                        case .idle: .easeOut(duration: 0.3)
                        }
                    }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                    let hasFailures = monitor.segments.failureCount > 0
                    HStack(spacing: 3) {
                        Image(systemName: hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption2)
                        Text("\(monitor.segments.failureCount) failed")
                            .font(.caption2.weight(.semibold))
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(hasFailures ? Color.red : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((hasFailures ? Color.red : Color(.systemGray3)).opacity(0.15), in: Capsule())
                }
                Text(monitor.segments.lastSegmentName ?? "Waiting for segments…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(lastSegmentAgo(now: now))
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(agoColor(now: now))
                    .contentTransition(.numericText())
                Text("since last")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .animation(.snappy(duration: 0.3), value: monitor.segments.failureCount)
    }

    /// Elapsed time since the last segment, never negative. A segment can be
    /// stamped a moment after the current timeline tick, which would otherwise
    /// read as being in the future.
    private func secondsSinceLastSegment(now: Date) -> TimeInterval? {
        guard let date = monitor.segments.lastSegmentDate else { return nil }
        return max(0, now.timeIntervalSince(date))
    }

    private func pulseColor(now: Date) -> Color {
        guard let gap = secondsSinceLastSegment(now: now) else { return Color(.systemGray3) }
        if gap > 12 { return .orange }
        return .green
    }

    private func agoColor(now: Date) -> Color {
        guard let gap = secondsSinceLastSegment(now: now) else { return .secondary }
        return gap > 12 ? .orange : .primary
    }

    private var statusText: String {
        if monitor.segments.count == 0 { return "Monitoring" }
        return "\(monitor.segments.count) segments"
    }

    private func lastSegmentAgo(now: Date) -> String {
        guard let gap = secondsSinceLastSegment(now: now) else { return "—" }
        let secs = Int(gap)
        if secs < 60 { return "\(secs)s" }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

// MARK: - Playback card

struct PlaybackCard: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        let stats = monitor.playback ?? PlaybackStats()
        return VStack(alignment: .leading, spacing: 8) {
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
            // Three explicit columns instead of a LazyVGrid so the buffer gauge
            // can span both rows of the middle column.
            HStack(alignment: .center, spacing: 8) {
                VStack(spacing: 8) {
                    StatCell(title: "Resolution", value: stats.resolutionText)
                    StatCell(title: "Dropped", value: "\(stats.droppedFrames)",
                             color: stats.droppedFrames > 0 ? .orange : .primary)
                }
                VStack(spacing: 8) {
                    StatCell(title: "Frames", value: stats.totalFrames > 0 ? "\(stats.totalFrames)" : "—")
                    StatCell(title: "Buffer", value: String(format: "%.1fs", stats.bufferedSeconds),
                             color: stats.bufferedSeconds < 2 && monitor.playback != nil ? .orange : .primary)
                }
                .overlay(alignment: .trailing) {
                    BufferGauge(seconds: stats.bufferedSeconds)
                        .padding(.vertical, 2)
                }
                VStack(spacing: 8) {
                    StatCell(title: "Position", value: timeString(stats.currentTime))
                    StatCell(title: "Rendition", value: monitor.activeVariant.map { "\($0.height ?? 0)p" } ?? "—")
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Segments card

struct SegmentsCard: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Segments", systemImage: "square.stack.3d.down.right")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatCell(title: "Loaded", value: "\(monitor.segments.count)")
                StatCell(title: "Transferred", value: monitor.segments.count > 0 ? monitor.segments.totalBytesText : "—")
                StatCell(title: "Throughput",
                         value: monitor.segments.averageBitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "—")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Download chart card

struct DownloadChartCard: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        let samples = monitor.segments.recentSamples
        let failures = monitor.segments.recentFailureMarkers
        let markers = monitor.segments.recentEventMarkers
        let thresholdMs = monitor.mediaTargetDuration.map { $0 * 1000 }
        // Anchor the scale to the real-time threshold when known so the chart
        // doesn't rescale (and change meaning) as peaks scroll off the window.
        let peak = max(samples.map(\.downloadMs).max() ?? 1, (thresholdMs ?? 0) * 1.15, 1)
        let qualitySwitches = markers.filter {
            if case .qualityChange = $0.kind { return true } else { return false }
        }
        let gaps = markers.filter {
            if case .downloadGap = $0.kind { return true } else { return false }
        }
        return VStack(alignment: .leading, spacing: 8) {
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
                    byteSizes: samples.map(\.bytes),
                    failureIndices: failures.map(\.sampleIndex),
                    qualitySwitchIndices: qualitySwitches.map(\.sampleIndex),
                    gapIndices: gaps.map(\.sampleIndex),
                    thresholdMs: thresholdMs,
                    thresholdLabel: monitor.mediaTargetDuration.map { String(format: "%.3gs", $0) },
                    peak: peak,
                    size: geo.size
                )
                .animation(.easeOut(duration: 0.3), value: samples.count)
                .animation(.easeOut(duration: 0.3), value: failures.count)
            }
            .frame(height: 64)

            HStack(spacing: 10) {
                Text(String(format: "Peak %.0f ms · %d recent segments", peak, samples.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !gaps.isEmpty {
                    ChartLegendTick(color: .orange, text: "\(gaps.count) gaps")
                }
                if !qualitySwitches.isEmpty {
                    ChartLegendTick(color: .purple, text: "\(qualitySwitches.count) switches")
                }
                ChartLegendTick(color: failures.isEmpty ? Color(.systemGray3) : .red,
                                text: failures.isEmpty ? "no failures" : "\(monitor.segments.failureCount) failed",
                                textColor: failures.isEmpty ? nil : .red)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Tiny tick-plus-count legend entry under the download chart.
private struct ChartLegendTick: View {
    let color: Color
    let text: String
    var textColor: Color?

    var body: some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 2, height: 10)
            Text(text)
                .font(.caption2)
                .foregroundStyle(textColor ?? .secondary)
        }
    }
}

/// Median / p95 / Peak / Failed download metrics for the recent segment window.
struct DownloadMetricsRow: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible()), count: 4)
        LazyVGrid(columns: columns, spacing: 12) {
            StatCard(title: "Median",
                     value: monitor.segments.downloadPercentileMs(0.5).map { String(format: "%.0f ms", $0) } ?? "—")
            StatCard(title: "p95",
                     value: monitor.segments.downloadPercentileMs(0.95).map { String(format: "%.0f ms", $0) } ?? "—",
                     color: (monitor.segments.downloadPercentileMs(0.95) ?? 0) > 2000 ? .orange : .primary)
            StatCard(title: "Peak",
                     value: monitor.segments.peakDownloadMs.map { String(format: "%.0f ms", $0) } ?? "—",
                     color: (monitor.segments.peakDownloadMs ?? 0) > 2000 ? .orange : .primary)
            StatCard(title: "Failed", value: "\(monitor.segments.failureCount)",
                     color: monitor.segments.failureCount > 0 ? .red : .primary)
        }
    }
}

// MARK: - Audio loudness card

/// LUFS loudness meter for the playing stream: momentary bar with an EBU R128
/// -23 LUFS reference tick, M / S / I / peak readouts, and a momentary history
/// sparkline. Data comes from the injected Web Audio K-weighted tap.
struct LoudnessCard: View {
    @ObservedObject var monitor: HLSMonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Audio Loudness", systemImage: "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let momentary = monitor.audio?.momentary {
                    Text(String(format: "%.1f LUFS", momentary))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
            }

            if let audio = monitor.audio {
                if audio.unavailable {
                    Text("This player keeps audio in WebKit's native pipeline, out of the page's reach. Device audio metering can measure it instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    meterDeviceAudioButton
                } else {
                    LoudnessMeterBar(momentary: audio.momentary, shortTerm: audio.shortTerm)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                        StatCell(title: "M", value: lufsText(audio.momentary))
                        StatCell(title: "S", value: lufsText(audio.shortTerm))
                        StatCell(title: "I", value: lufsText(audio.integrated))
                        StatCell(title: "Peak", value: audio.peakDbfs.map { String(format: "%.1f dB", $0) } ?? "—")
                    }

                    if monitor.audioHistory.count >= 2 {
                        GeometryReader { geo in
                            // Reuse the download chart with LUFS shifted into a
                            // positive 0...60 range (-60 LUFS at the baseline).
                            LineChart(
                                values: monitor.audioHistory.map { min(max($0 + 60, 0), 60) },
                                peak: 60,
                                size: geo.size
                            )
                        }
                        .frame(height: 36)
                    }

                    if monitor.nativeMeteringActive {
                        HStack {
                            Text("Metering the device's audio output")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop") {
                                monitor.stopNativeAudioMetering()
                            }
                            .font(.caption2.weight(.semibold))
                        }
                    }
                }
            } else {
                Text("LUFS loudness meters automatically when a raw .m3u8 plays in the inline player. For other players, meter the device's audio output instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                meterDeviceAudioButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var meterDeviceAudioButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                monitor.startNativeAudioMetering()
            } label: {
                Label("Meter Device Audio", systemImage: "waveform.badge.mic")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            Text("Uses iOS in-app screen capture (audio only). A consent prompt and capture indicator appear; nothing is recorded.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    private func lufsText(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "−∞"
    }
}

/// Horizontal momentary-loudness bar on a -40...0 LUFS scale with a
/// short-term marker line and the EBU R128 -23 LUFS reference tick.
private struct LoudnessMeterBar: View {
    let momentary: Double?
    let shortTerm: Double?

    private static let floorLufs: Double = -40

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(geo.size.width * fraction(of: momentary), 4))

                // Short-term marker.
                if let shortTerm {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 14)
                        .position(x: geo.size.width * fraction(of: shortTerm), y: geo.size.height / 2)
                }

                // EBU R128 programme target.
                let targetX = geo.size.width * fraction(of: -23)
                Rectangle()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 1.5, height: geo.size.height)
                    .position(x: targetX, y: geo.size.height / 2)
                Text("-23")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .position(x: targetX, y: -6)
            }
        }
        .frame(height: 10)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.15), value: momentary)
    }

    private func fraction(of lufs: Double?) -> CGFloat {
        guard let lufs else { return 0 }
        return CGFloat(min(max((lufs - Self.floorLufs) / -Self.floorLufs, 0), 1))
    }

    private var fillColor: Color {
        guard let momentary else { return .green }
        if momentary > -9 { return .red }
        if momentary > -14 { return .orange }
        return .green
    }
}

// MARK: - Buffer gauge

/// Vertical gauge of remaining playback buffer. Full at 30s or more, draining
/// toward the bottom as the buffer shrinks; yellow under 10s, red when empty.
struct BufferGauge: View {
    let seconds: Double

    private static let fullScale: Double = 30

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color(.systemGray5))
                Capsule()
                    .fill(color)
                    .frame(height: max(geo.size.height * fill, 3))
                // Notches marking the 10s and 20s levels, drawn in the card's
                // background color so they read as subtle gaps in the bar,
                // with tiny labels floating just left of the bar.
                ForEach([10, 20], id: \.self) { mark in
                    let y = geo.size.height * (1 - CGFloat(mark) / CGFloat(Self.fullScale))
                    Rectangle()
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(width: geo.size.width, height: 1.5)
                        .position(x: geo.size.width / 2, y: y)
                    Text("\(mark)s")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: -8, y: y)
                }
            }
        }
        .frame(width: 5)
        .animation(.easeOut(duration: 0.3), value: seconds)
    }

    private var fill: CGFloat {
        CGFloat(min(max(seconds, 0) / Self.fullScale, 1))
    }

    private var color: Color {
        if seconds <= 0 { return .red }
        if seconds < 10 { return .yellow }
        return .green
    }
}

// MARK: - Line Chart

/// Smooth line chart with a soft area fill and endpoint dot for download times.
struct LineChart: View {
    let values: [Double]
    var byteSizes: [Int] = []
    var failureIndices: [Int] = []
    var qualitySwitchIndices: [Int] = []
    var gapIndices: [Int] = []
    var thresholdMs: Double?
    var thresholdLabel: String?
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

            // Real-time line: a segment plotted above it took longer to
            // download than it takes to play, so the player is falling behind.
            if let thresholdY {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: thresholdY))
                    path.addLine(to: CGPoint(x: size.width, y: thresholdY))
                }
                .stroke(Color.red.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                if let thresholdLabel {
                    Text(thresholdLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.7))
                        .position(x: size.width - 10, y: thresholdY - 7)
                }
            }

            // Download gaps (silence between segments) and rendition switches,
            // drawn behind the line like the failure marks.
            ForEach(xPositions(for: gapIndices), id: \.self) { x in
                Rectangle()
                    .fill(Color.orange.opacity(0.7))
                    .frame(width: 2, height: size.height)
                    .position(x: x, y: size.height / 2)
            }
            ForEach(xPositions(for: qualitySwitchIndices), id: \.self) { x in
                Rectangle()
                    .fill(Color.purple.opacity(0.6))
                    .frame(width: 1.5, height: size.height)
                    .position(x: x, y: size.height / 2)
            }

            // Vertical marks for failed segment downloads (drawn behind the line).
            ForEach(xPositions(for: failureIndices), id: \.self) { x in
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

                // Per-sample dots sized by segment bytes: separates "network
                // got slow" (same-size dots, higher line) from "segments got
                // bigger" (bigger dots, higher line — e.g. an ABR step-up).
                if let maxBytes = byteSizes.max(), maxBytes > 0 {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                        let bytes = index < byteSizes.count ? byteSizes[index] : 0
                        // sqrt so perceived dot area tracks the byte count.
                        let radius = 1.2 + 2.2 * sqrt(Double(bytes) / Double(maxBytes))
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: radius * 2, height: radius * 2)
                            .position(point)
                    }
                }

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

    /// Y position of the real-time threshold, using the same scale as the samples.
    private var thresholdY: CGFloat? {
        guard let thresholdMs, thresholdMs > 0, peak > 0 else { return nil }
        let topInset: CGFloat = 6
        let usableHeight = max(size.height - topInset, 1)
        return topInset + (1 - CGFloat(thresholdMs / peak)) * usableHeight
    }

    /// X positions for event marks, mapped onto the same horizontal scale as the samples.
    private func xPositions(for indices: [Int]) -> [CGFloat] {
        guard size.width > 0 else { return [] }
        let count = values.count
        let stepX = count > 1 ? size.width / CGFloat(count - 1) : 0
        return indices.map { rawIndex in
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

// MARK: - Stream rows

struct StreamHeaderView: View {
    let stream: HLSStream

    var body: some View {
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

struct VariantRow: View {
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

// MARK: - Event row

struct EventRow: View {
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

// MARK: - Small shared bits

struct StatCard: View {
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

struct StatCell: View {
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

struct StatusBadge: View {
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

struct EmptyStateView: View {
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
