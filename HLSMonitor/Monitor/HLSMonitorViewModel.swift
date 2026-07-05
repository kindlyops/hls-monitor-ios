//
//  HLSMonitorViewModel.swift
//  HLSMonitor
//

import Foundation
import Combine

@MainActor
final class HLSMonitorViewModel: ObservableObject {

    @Published private(set) var events: [MonitorEvent] = []
    @Published private(set) var streams: [HLSStream] = []
    @Published private(set) var playback: PlaybackStats?
    @Published private(set) var segments = SegmentTracker()
    @Published private(set) var audio: AudioLoudness?
    /// Rolling momentary-loudness history for the loudness sparkline
    /// (~30s at the 200ms reporting cadence).
    @Published private(set) var audioHistory: [Double] = []

    private var knownManifestURLs: Set<String> = []
    private var fetchingURLs: Set<String> = []
    private var recentBitrates: [Double] = []
    private var lastQuality: String = ""
    private let maxEvents = 400

    // MARK: - Public

    func reset() {
        events.removeAll()
        streams.removeAll()
        playback = nil
        segments = SegmentTracker()
        audio = nil
        audioHistory.removeAll()
        knownManifestURLs.removeAll()
        fetchingURLs.removeAll()
        recentBitrates.removeAll()
        lastQuality = ""
        log(.info, "Monitoring reset", detail: "New page loaded")
    }

    /// Target segment duration of the most recently refreshed media playlist,
    /// used to relate download times to real-time playback on the chart.
    var mediaTargetDuration: Double? {
        streams.filter { !$0.isMaster }
            .max { $0.lastUpdated < $1.lastUpdated }?
            .targetDuration
    }

    var activeVariant: HLSVariant? {
        guard let height = playback?.height, height > 0 else { return nil }
        let allVariants = streams.flatMap { $0.variants }
        return allVariants.first { $0.height == height }
            ?? allVariants.min { abs(($0.height ?? 0) - height) < abs(($1.height ?? 0) - height) }
    }

    func handle(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "manifestRequest":
            if let urlString = body["url"] as? String {
                manifestSeen(urlString)
            }
        case "segment":
            handleSegment(body)
        case "segmentError":
            handleSegmentError(body)
        case "event":
            handlePlayerEvent(body)
        case "stats":
            handleStats(body)
        case "audio":
            handleAudio(body)
        default:
            break
        }
    }

    func refreshStream(_ stream: HLSStream) {
        fetchManifest(stream.url.absoluteString, isRefresh: true)
    }

    // MARK: - Handlers

    private func manifestSeen(_ urlString: String) {
        guard !knownManifestURLs.contains(urlString) else { return }
        knownManifestURLs.insert(urlString)
        log(.manifest, "Manifest detected", detail: shortName(urlString))
        fetchManifest(urlString, isRefresh: false)
    }

    private func fetchManifest(_ urlString: String, isRefresh: Bool) {
        guard let url = URL(string: urlString), !fetchingURLs.contains(urlString) else { return }
        fetchingURLs.insert(urlString)

        Task {
            defer { fetchingURLs.remove(urlString) }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let text = String(data: data, encoding: .utf8),
                      let parsed = ManifestParser.parse(text) else {
                    log(.error, "Manifest parse failed", detail: shortName(urlString))
                    return
                }
                applyParsedManifest(parsed, url: url)
                if parsed.isMaster {
                    log(.manifest, "Master playlist parsed",
                        detail: "\(parsed.variants.count) quality levels available")
                } else if !isRefresh {
                    log(.manifest, "Media playlist parsed",
                        detail: "\(parsed.segmentCount) segments · \(parsed.isLive ? "LIVE" : "VOD")")
                }
            } catch {
                log(.error, "Manifest fetch failed", detail: error.localizedDescription)
            }
        }
    }

    private func applyParsedManifest(_ parsed: ParsedManifest, url: URL) {
        let stream = HLSStream(
            url: url,
            isMaster: parsed.isMaster,
            variants: parsed.variants,
            targetDuration: parsed.targetDuration,
            segmentCount: parsed.segmentCount,
            isLive: parsed.isLive,
            lastUpdated: Date()
        )
        if let index = streams.firstIndex(where: { $0.url == url }) {
            streams[index] = stream
        } else {
            // Masters first so quality levels surface at the top.
            if parsed.isMaster {
                streams.insert(stream, at: 0)
            } else {
                streams.append(stream)
            }
        }
    }

    private func handleSegment(_ body: [String: Any]) {
        let urlString = body["url"] as? String ?? ""
        let durationMs = (body["durationMs"] as? NSNumber)?.doubleValue ?? 0
        let bytes = (body["bytes"] as? NSNumber)?.intValue ?? 0

        segments.count += 1
        segments.totalBytes += max(bytes, 0)
        segments.lastSegmentName = shortName(urlString)

        // A long silence between downloads is a stall the per-sample chart
        // can't show on its own — mark it so it doesn't pass unnoticed.
        let now = Date()
        if let previous = segments.lastSegmentDate {
            let gap = now.timeIntervalSince(previous)
            let gapThreshold = max(2 * (mediaTargetDuration ?? 6), 8)
            if gap > gapThreshold {
                appendEventMarker(.downloadGap(gap))
                log(.error, "Download gap", detail: String(format: "%.0f s without a segment", gap))
            }
        }
        segments.lastSegmentDate = now

        // Record a sample for the download-time graph (keep a rolling window).
        if durationMs > 0 {
            segments.recentSamples.append(SegmentSample(downloadMs: durationMs, bytes: max(bytes, 0), date: now))
            if segments.recentSamples.count > 30 {
                segments.recentSamples.removeFirst()
                // Shift markers left to stay aligned with the trimmed window,
                // dropping any that scroll off the left edge.
                for index in segments.recentFailureMarkers.indices {
                    segments.recentFailureMarkers[index].sampleIndex -= 1
                }
                segments.recentFailureMarkers.removeAll { $0.sampleIndex < 0 }
                for index in segments.recentEventMarkers.indices {
                    segments.recentEventMarkers[index].sampleIndex -= 1
                }
                segments.recentEventMarkers.removeAll { $0.sampleIndex < 0 }
            }
        }

        var detail = String(format: "%.0f ms", durationMs)
        if bytes > 0, durationMs > 0 {
            let mbps = (Double(bytes) * 8 / (durationMs / 1000)) / 1_000_000
            segments.lastBitrateMbps = mbps
            recentBitrates.append(mbps)
            if recentBitrates.count > 12 { recentBitrates.removeFirst() }
            segments.averageBitrateMbps = recentBitrates.reduce(0, +) / Double(recentBitrates.count)
            detail += String(format: " · %.1f KB · %.1f Mbps", Double(bytes) / 1024, mbps)
        }
        log(.segment, "Segment \(shortName(urlString))", detail: detail)
    }

    private func handleSegmentError(_ body: [String: Any]) {
        let urlString = body["url"] as? String ?? ""
        let reason = body["reason"] as? String ?? "error"
        let name = shortName(urlString)

        segments.failureCount += 1
        segments.lastFailureName = name
        segments.lastFailureDate = Date()

        // Anchor the failure marker to the current position in the sample window
        // so it renders as a vertical line at the point in time it happened.
        let marker = SegmentFailureMarker(
            sampleIndex: segments.recentSamples.count,
            date: Date(),
            reason: reason
        )
        segments.recentFailureMarkers.append(marker)
        if segments.recentFailureMarkers.count > 30 {
            segments.recentFailureMarkers.removeFirst()
        }

        log(.error, "Segment failed \(name)", detail: reason)
    }

    private func handlePlayerEvent(_ body: [String: Any]) {
        let name = body["name"] as? String ?? ""
        let detail = body["detail"] as? String ?? ""

        switch name {
        case "videoFound":
            log(.info, "Video player detected", detail: detail.isEmpty ? "Watching for HLS traffic" : shortName(detail))
        case "qualityChange":
            guard detail != lastQuality else { return }
            // The first report is the starting rendition, not a switch.
            if !lastQuality.isEmpty {
                appendEventMarker(.qualityChange(detail))
            }
            lastQuality = detail
            log(.quality, "Rendition changed", detail: detail)
        case "error":
            log(.error, "Player error", detail: detail)
        case "recovered":
            log(.playback, "Playback recovered", detail: detail.isEmpty ? "resumed after foreground" : detail)
        case "waiting", "stalled":
            log(.error, "Buffering (\(name))")
        case "play", "pause", "ended", "loadedmetadata":
            log(.playback, name.capitalized, detail: detail)
        default:
            log(.playback, name, detail: detail)
        }
    }

    private func handleStats(_ body: [String: Any]) {
        var stats = PlaybackStats()
        stats.width = (body["width"] as? NSNumber)?.intValue ?? 0
        stats.height = (body["height"] as? NSNumber)?.intValue ?? 0
        stats.currentTime = (body["currentTime"] as? NSNumber)?.doubleValue ?? 0
        stats.bufferedSeconds = (body["buffered"] as? NSNumber)?.doubleValue ?? 0
        stats.droppedFrames = (body["dropped"] as? NSNumber)?.intValue ?? 0
        stats.totalFrames = (body["totalFrames"] as? NSNumber)?.intValue ?? 0
        stats.paused = (body["paused"] as? NSNumber)?.boolValue ?? true
        playback = stats
    }

    private func handleAudio(_ body: [String: Any]) {
        guard (body["state"] as? String) != "unavailable" else {
            audio = AudioLoudness(unavailable: true)
            log(.info, "Loudness metering unavailable",
                detail: "Native HLS playback keeps audio outside the page")
            return
        }
        var levels = AudioLoudness()
        levels.momentary = (body["momentary"] as? NSNumber)?.doubleValue
        levels.shortTerm = (body["shortTerm"] as? NSNumber)?.doubleValue
        levels.integrated = (body["integrated"] as? NSNumber)?.doubleValue
        levels.peakDbfs = (body["peak"] as? NSNumber)?.doubleValue
        audio = levels
        audioHistory.append(levels.momentary ?? -70)
        if audioHistory.count > 150 {
            audioHistory.removeFirst(audioHistory.count - 150)
        }
    }

    // MARK: - Helpers

    private func appendEventMarker(_ kind: SegmentEventMarker.Kind) {
        segments.recentEventMarkers.append(
            SegmentEventMarker(sampleIndex: segments.recentSamples.count, date: Date(), kind: kind)
        )
        if segments.recentEventMarkers.count > 30 {
            segments.recentEventMarkers.removeFirst()
        }
    }

    private func log(_ kind: MonitorEventKind, _ title: String, detail: String = "") {
        events.append(MonitorEvent(kind: kind, title: title, detail: detail))
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    private func shortName(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let name = url.lastPathComponent
        return name.isEmpty ? urlString : name
    }
}
