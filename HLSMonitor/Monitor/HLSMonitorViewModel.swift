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
        knownManifestURLs.removeAll()
        fetchingURLs.removeAll()
        recentBitrates.removeAll()
        lastQuality = ""
        log(.info, "Monitoring reset", detail: "New page loaded")
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
        case "event":
            handlePlayerEvent(body)
        case "stats":
            handleStats(body)
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
        segments.lastSegmentDate = Date()

        // Record a sample for the download-time graph (keep a rolling window).
        if durationMs > 0 {
            segments.recentSamples.append(SegmentSample(downloadMs: durationMs, bytes: max(bytes, 0), date: Date()))
            if segments.recentSamples.count > 30 { segments.recentSamples.removeFirst() }
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

    private func handlePlayerEvent(_ body: [String: Any]) {
        let name = body["name"] as? String ?? ""
        let detail = body["detail"] as? String ?? ""

        switch name {
        case "videoFound":
            log(.info, "Video player detected", detail: detail.isEmpty ? "Watching for HLS traffic" : shortName(detail))
        case "qualityChange":
            guard detail != lastQuality else { return }
            lastQuality = detail
            log(.quality, "Rendition changed", detail: detail)
        case "error":
            log(.error, "Player error", detail: detail)
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

    // MARK: - Helpers

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
