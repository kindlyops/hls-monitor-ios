//
//  QualityReportHTML.swift
//  HLSMonitor
//
//  Renders a MonitoringSession as a single-page, self-contained HTML report
//  styled after the kindlyops/cuesheet Typst template: white page, Helvetica,
//  bold title with right-aligned metadata over a heavy rule, tables with
//  hairline row separators and tracked uppercase gray headers, teal #235a68
//  accents, and sparkbars. Sized to US Letter at 72dpi (612×792) so
//  WKWebView.createPDF yields exactly one page.
//

import Foundation

enum QualityReportHTML {

    private static let teal = "#235a68"
    private static let eventColors: [QualityEvent.Kind: String] = [
        .failure: "#a33d2f",
        .gap: "#c2762c",
        .stall: "#b3953d",
        .qualitySwitch: "#235a68",
    ]
    private static let eventLabels: [QualityEvent.Kind: String] = [
        .failure: "Failure",
        .gap: "Gap",
        .stall: "Stall",
        .qualitySwitch: "Rendition switch",
    ]
    /// Bucket order when picking a cluster's color: worst wins.
    private static let severityOrder: [QualityEvent.Kind] = [.failure, .gap, .stall, .qualitySwitch]

    static func page(for session: MonitoringSession, generatedAt: Date = Date()) -> String {
        let day = DateFormatter()
        day.dateStyle = .long
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short

        let health = healthAssessment(session)
        let meta = [
            day.string(from: session.startDate),
            "\(time.string(from: session.startDate)) – \(time.string(from: session.endDate))",
            session.consolidatedCount > 1 ? "\(session.consolidatedCount) sessions" : "1 session",
            session.isLive.map { $0 ? "LIVE" : "VOD" } ?? nil,
        ].compactMap { $0 }.joined(separator: " · ")

        let incidentMax = max(session.failureCount, session.gapCount,
                              session.stallCount, session.qualitySwitchCount, 1)

        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <style>
        * { box-sizing: border-box; margin: 0; }
        html, body { width: 612px; height: 792px; overflow: hidden; }
        body {
          font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
          font-size: 10px;
          color: #111;
          background: #fff;
          padding: 42px 42px 36px;
          font-variant-numeric: tabular-nums;
          -webkit-print-color-adjust: exact;
        }
        .titlebar { display: flex; justify-content: space-between; align-items: flex-end; }
        .titlebar h1 { font-size: 18px; font-weight: 700; letter-spacing: -0.2px; }
        .titlebar .meta { font-size: 9.5px; color: #666; text-align: right; }
        .verdict { font-weight: 800; letter-spacing: 1px; }
        .rule { border: 0; border-top: 1.2px solid #111; margin: 6px 0 5px; }
        .url { font-family: Menlo, monospace; font-size: 7.5px; color: #808080; word-break: break-all; }

        .stats { display: flex; margin-top: 16px; border-top: 0.6px solid #8c8c8c; border-bottom: 0.6px solid #8c8c8c; }
        .stat { flex: 1; padding: 8px 10px; border-right: 0.3px solid #e0e0e0; }
        .stat:last-child { border-right: 0; }
        .stat b { display: block; font-size: 14px; font-weight: 700; color: \(teal); }
        .stat span { font-size: 7.5px; letter-spacing: 0.8px; text-transform: uppercase; color: #737373; }

        .label { font-size: 7.5px; letter-spacing: 0.8px; text-transform: uppercase; color: #737373; margin: 18px 0 6px; }

        table { width: 100%; border-collapse: collapse; }
        th { font-size: 7.5px; font-weight: 500; letter-spacing: 0.5px; text-transform: uppercase;
             color: #737373; text-align: left; padding: 0 8px 5px; border-bottom: 0.6px solid #8c8c8c; }
        td { padding: 8px; border-bottom: 0.3px solid #e0e0e0; vertical-align: middle; font-size: 10px; }
        tr:last-child td { border-bottom: 0.3px solid #e0e0e0; }
        td.count { font-size: 12px; font-weight: 700; color: \(teal); width: 44px; }
        td.note { color: #808080; font-size: 9px; }
        .spark { width: 110px; }
        .spark .track { width: 100%; height: 4px; background: #e5e5e5; }
        .spark .fill { height: 100%; background: \(teal); }

        .timeline-caption { font-size: 8px; color: #999; margin-top: 3px; }
        .legend { display: flex; gap: 14px; margin-top: 5px; font-size: 7.5px; color: #555; }
        .legend i { display: inline-block; width: 7px; height: 7px; margin-right: 4px; }

        .footer { position: absolute; bottom: 26px; left: 42px; right: 42px;
                  border-top: 0.5px solid #c7c7c7; padding-top: 4px;
                  display: flex; justify-content: space-between;
                  font-size: 7.5px; color: #8c8c8c; }
        </style></head><body>
        <div class="titlebar">
          <h1>Stream Quality Report — \(escape(displayName(for: session.streamURL)))</h1>
          <div class="meta">\(escape(meta))<br>
            <span class="verdict" style="color:\(health.color)">\(health.label)</span></div>
        </div>
        <hr class="rule">
        <div class="url">\(escape(session.streamURL))</div>

        <div class="stats">
          <div class="stat"><b>\(durationText(session.monitoredSeconds))</b><span>Monitored</span></div>
          <div class="stat"><b>\(session.segmentCount)</b><span>Segments</span></div>
          <div class="stat"><b>\(bytesText(session.totalBytes))</b><span>Downloaded</span></div>
          <div class="stat"><b>\(session.averageBitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "—")</b><span>Avg throughput</span></div>
          <div class="stat"><b>\(escape(session.lastResolution ?? "—"))</b><span>Resolution</span></div>
        </div>

        <div class="label">Timeline — quality events over the monitored window</div>
        \(timelineSVG(for: session, timeFormatter: time))
        \(session.events.isEmpty
            ? "<div class=\"timeline-caption\">No quality events were observed during monitoring.</div>"
            : "<div class=\"legend\">" + severityOrder.map {
                "<span><i style=\"background:\(eventColors[$0]!)\"></i>\(eventLabels[$0]!)</span>"
              }.joined() + "<span><i style=\"background:#e8edee\"></i>Monitored coverage</span></div>")

        <div class="label">Incidents</div>
        <table>
          <tr><th>Incident</th><th>Count</th><th></th><th>Meaning</th></tr>
          \(incidentRow("Failed segment downloads", session.failureCount, incidentMax,
                        "Requests that errored or returned HTTP ≥ 400"))
          \(incidentRow("Download gaps", session.gapCount, incidentMax,
                        "Silence over 2× target duration between segments"))
          \(incidentRow("Playback stalls", session.stallCount, incidentMax,
                        "Player reported waiting or stalled"))
          \(incidentRow("Rendition switches", session.qualitySwitchCount, incidentMax,
                        "ABR changed quality level mid-play"))
        </table>

        <div class="label">Segment download time</div>
        <table>
          <tr><th>Median</th><th>P95</th><th>Peak</th></tr>
          <tr>
            <td class="count">\(msText(session.medianDownloadMs))</td>
            <td class="count">\(msText(session.p95DownloadMs))</td>
            <td class="count">\(msText(session.peakDownloadMs))</td>
          </tr>
        </table>

        <div class="footer">
          <span>Generated by HLSMonitor · \(day.string(from: generatedAt)) \(time.string(from: generatedAt))</span>
          <span>1 / 1</span>
        </div>
        </body></html>
        """
    }

    // MARK: - Timeline

    /// Draws the monitored window as a horizontal band: light coverage spans
    /// (with white gaps between consolidated sessions), event ticks bucketed
    /// into clusters whose height scales with the cluster size and whose
    /// color reflects the most severe event kind in the bucket.
    static func timelineSVG(for session: MonitoringSession, timeFormatter: DateFormatter) -> String {
        let width = 528.0
        let height = 74.0
        let trackY = 30.0
        let trackHeight = 12.0
        let start = session.startDate.timeIntervalSince1970
        let end = session.endDate.timeIntervalSince1970
        let span = max(end - start, 1)

        func x(_ date: Date) -> Double {
            (date.timeIntervalSince1970 - start) / span * width
        }

        var svg = """
        <svg width="\(Int(width))" height="\(Int(height))" viewBox="0 0 \(Int(width)) \(Int(height))" xmlns="http://www.w3.org/2000/svg">
        <rect x="0" y="\(trackY)" width="\(width)" height="\(trackHeight)" fill="#ffffff" stroke="#d9d9d9" stroke-width="0.6"/>
        """

        // Coverage spans: what was actually monitored.
        for spanItem in session.spans {
            let x0 = x(spanItem.start)
            let x1 = x(spanItem.end)
            svg += "<rect x=\"\(fmt(x0))\" y=\"\(trackY)\" width=\"\(fmt(max(x1 - x0, 1)))\" height=\"\(trackHeight)\" fill=\"#e8edee\"/>"
        }

        // Bucket events into clusters (~5px buckets).
        let bucketCount = 104
        var buckets: [[QualityEvent.Kind: Int]] = Array(repeating: [:], count: bucketCount)
        for event in session.events {
            let position = (event.date.timeIntervalSince1970 - start) / span
            let index = min(max(Int(position * Double(bucketCount)), 0), bucketCount - 1)
            buckets[index][event.kind, default: 0] += 1
        }

        for (index, bucket) in buckets.enumerated() where !bucket.isEmpty {
            let total = bucket.values.reduce(0, +)
            let kind = severityOrder.first { bucket[$0] != nil } ?? .qualitySwitch
            let color = eventColors[kind]!
            let tickX = (Double(index) + 0.5) / Double(bucketCount) * width
            let tickHeight = min(10.0 + Double(total - 1) * 4.0, 26.0)
            svg += "<rect x=\"\(fmt(tickX - 1.25))\" y=\"\(fmt(trackY - tickHeight))\" width=\"2.5\" height=\"\(fmt(tickHeight + trackHeight))\" fill=\"\(color)\"/>"
            if total >= 3 {
                svg += "<text x=\"\(fmt(tickX))\" y=\"\(fmt(trackY - tickHeight - 3))\" text-anchor=\"middle\" font-family=\"Helvetica Neue, Arial\" font-size=\"7\" fill=\"\(color)\">\(total)</text>"
            }
        }

        // Axis labels: start, midpoint, end.
        let mid = Date(timeIntervalSince1970: start + span / 2)
        let labelY = trackY + trackHeight + 13
        svg += "<text x=\"0\" y=\"\(fmt(labelY))\" font-family=\"Helvetica Neue, Arial\" font-size=\"7.5\" fill=\"#8c8c8c\">\(timeFormatter.string(from: session.startDate))</text>"
        svg += "<text x=\"\(fmt(width / 2))\" y=\"\(fmt(labelY))\" text-anchor=\"middle\" font-family=\"Helvetica Neue, Arial\" font-size=\"7.5\" fill=\"#8c8c8c\">\(timeFormatter.string(from: mid))</text>"
        svg += "<text x=\"\(fmt(width))\" y=\"\(fmt(labelY))\" text-anchor=\"end\" font-family=\"Helvetica Neue, Arial\" font-size=\"7.5\" fill=\"#8c8c8c\">\(timeFormatter.string(from: session.endDate))</text>"
        svg += "</svg>"
        return svg
    }

    // MARK: - Rows and helpers

    private static func incidentRow(
        _ name: String, _ count: Int, _ maxCount: Int, _ meaning: String
    ) -> String {
        // Sparkbar proportion uses sqrt like the cuesheet pace bars, so small
        // counts stay visible next to large ones.
        let fraction = maxCount > 0 ? (Double(count) / Double(maxCount)).squareRoot() : 0
        return """
        <tr><td>\(escape(name))</td><td class="count">\(count)</td>
        <td class="spark"><div class="track"><div class="fill" style="width:\(fmt(fraction * 100))%"></div></div></td>
        <td class="note">\(escape(meaning))</td></tr>
        """
    }

    private static func healthAssessment(
        _ s: MonitoringSession
    ) -> (label: String, color: String) {
        if s.failureCount >= 5 || s.gapCount >= 3 || s.stallCount >= 3 {
            return ("POOR", eventColors[.failure]!)
        }
        if s.failureCount + s.gapCount + s.stallCount > 0 {
            return ("DEGRADED", eventColors[.gap]!)
        }
        return ("HEALTHY", teal)
    }

    private static func displayName(for url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return "\(total)s"
    }

    private static func bytesText(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private static func msText(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
