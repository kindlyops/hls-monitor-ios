//
//  QualityReportHTML.swift
//  HLSMonitor
//
//  Renders a MonitoringSession as a single-page, self-contained HTML report
//  in the design-memo editorial style (Arrival palette, serif headings,
//  ruled tables, eyebrow labels). The page is sized to US Letter at 72dpi
//  (612×792) so WKWebView.createPDF yields exactly one page.
//

import Foundation

enum QualityReportHTML {

    static func page(for session: MonitoringSession, generatedAt: Date = Date()) -> String {
        let day = DateFormatter()
        day.dateStyle = .long
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short

        let health = healthAssessment(session)
        let window = session.consolidatedCount > 1
            ? "\(time.string(from: session.startDate)) – \(time.string(from: session.endDate)) · \(session.consolidatedCount) sessions consolidated"
            : "\(time.string(from: session.startDate)) – \(time.string(from: session.endDate))"

        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <style>
        :root {
          --paper: #cfd4cf; --panel: #e6e6df; --ink: #171c1d; --muted: #4a5250;
          --olive: #4a4f3f; --amber: #9a7a55; --ochre: #b79b65; --teal: #2f5557;
          --blue: #5f7f86; --line: #9aa39d;
        }
        * { box-sizing: border-box; margin: 0; }
        html, body { width: 612px; height: 792px; overflow: hidden; }
        body {
          font-family: Georgia, "Times New Roman", serif;
          color: var(--ink);
          background:
            radial-gradient(circle at 14% 0%, rgba(214,199,164,0.5), transparent 300px),
            radial-gradient(circle at 86% 8%, rgba(95,127,134,0.28), transparent 320px),
            linear-gradient(135deg, #dce0dc, var(--paper) 52%, #b9c1bc);
          padding: 34px 40px 28px;
          -webkit-print-color-adjust: exact;
        }
        .eyebrow {
          display: flex; align-items: center; gap: 7px;
          color: var(--teal);
          font-family: -apple-system, "Helvetica Neue", sans-serif;
          font-size: 9px; font-weight: 700; letter-spacing: 2px;
          text-transform: uppercase; margin-bottom: 8px;
        }
        .eyebrow::before {
          content: ""; width: 8px; height: 8px; border-radius: 999px;
          background: var(--ochre);
        }
        h1 {
          color: var(--olive); font-size: 30px; font-weight: 500;
          letter-spacing: -0.5px; line-height: 1.08;
          border-bottom: 3px double var(--olive); padding-bottom: 12px;
        }
        .meta {
          display: flex; justify-content: space-between; align-items: baseline;
          margin-top: 8px; font-size: 11px; color: var(--muted);
          font-family: -apple-system, "Helvetica Neue", sans-serif;
        }
        .url {
          font-family: Menlo, monospace; font-size: 10px; color: var(--ink);
          word-break: break-all; margin-top: 6px;
        }
        .verdict {
          display: inline-block; padding: 3px 10px; border-radius: 999px;
          font-family: -apple-system, "Helvetica Neue", sans-serif;
          font-size: 10px; font-weight: 800; letter-spacing: 0.5px;
        }
        .verdict.good { background: rgba(31,63,70,0.18); color: #1f3f46; }
        .verdict.fair { background: rgba(214,199,164,0.55); color: #5e4a2e; }
        .verdict.poor { background: rgba(154,122,85,0.35); color: var(--olive); }
        .stats {
          display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px;
          margin-top: 16px;
        }
        .stat {
          border: 1px solid var(--line); background: rgba(230,230,223,0.85);
          border-top: 3px solid var(--olive); padding: 9px 10px;
        }
        .stat b {
          display: block; font-size: 17px; color: var(--olive); font-weight: 600;
        }
        .stat span {
          font-family: -apple-system, "Helvetica Neue", sans-serif;
          font-size: 8.5px; font-weight: 700; letter-spacing: 1px;
          text-transform: uppercase; color: var(--muted);
        }
        h2 {
          color: var(--olive); font-size: 15px; font-weight: 600;
          margin-top: 18px; margin-bottom: 2px;
        }
        table {
          width: 100%; border-collapse: collapse; margin-top: 6px;
          border-top: 2px solid var(--ink); border-bottom: 2px solid var(--ink);
          font-family: -apple-system, "Helvetica Neue", sans-serif; font-size: 10.5px;
        }
        th, td { text-align: left; padding: 6px 9px; border-bottom: 1px solid var(--line); }
        th {
          background: rgba(214,199,164,0.32); font-size: 8.5px;
          letter-spacing: 1px; text-transform: uppercase;
        }
        td.num { font-variant-numeric: tabular-nums; }
        tr:last-child td { border-bottom: 0; }
        .badge {
          display: inline-block; padding: 1.5px 8px; border-radius: 999px;
          font-size: 9px; font-weight: 800;
        }
        .badge.ok { background: rgba(31,63,70,0.16); color: #1f3f46; }
        .badge.warn { background: rgba(214,199,164,0.55); color: #5e4a2e; }
        .badge.bad { background: rgba(154,122,85,0.35); color: var(--olive); }
        .callout {
          margin-top: 14px; padding: 6px 0 6px 12px;
          border-left: 3px solid var(--teal); color: var(--muted);
          font-style: italic; font-size: 11px;
        }
        .footer {
          position: absolute; bottom: 26px; left: 40px; right: 40px;
          display: flex; justify-content: space-between;
          border-top: 1px solid var(--line); padding-top: 7px;
          font-family: -apple-system, "Helvetica Neue", sans-serif;
          font-size: 8.5px; color: var(--muted); letter-spacing: 0.4px;
        }
        </style></head><body>
        <div class="eyebrow">Stream Quality Report</div>
        <h1>\(escape(displayName(for: session.streamURL)))</h1>
        <div class="meta">
          <span>\(day.string(from: session.startDate)) · \(window)</span>
          <span class="verdict \(health.cssClass)">\(health.label)</span>
        </div>
        <div class="url">\(escape(session.streamURL))</div>

        <div class="stats">
          <div class="stat"><b>\(durationText(session.monitoredSeconds))</b><span>Monitored</span></div>
          <div class="stat"><b>\(session.segmentCount)</b><span>Segments</span></div>
          <div class="stat"><b>\(bytesText(session.totalBytes))</b><span>Downloaded</span></div>
          <div class="stat"><b>\(session.averageBitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "—")</b><span>Avg throughput</span></div>
        </div>

        <h2>Incidents observed</h2>
        <table>
          <tr><th>Incident</th><th>Count</th><th>Assessment</th><th>Meaning</th></tr>
          <tr><td>Failed segment downloads</td><td class="num">\(session.failureCount)</td>
              <td>\(countBadge(session.failureCount, warnAt: 1, badAt: 5))</td>
              <td>Requests that errored or returned HTTP ≥ 400</td></tr>
          <tr><td>Download gaps</td><td class="num">\(session.gapCount)</td>
              <td>\(countBadge(session.gapCount, warnAt: 1, badAt: 3))</td>
              <td>Silence over 2× target duration between segments</td></tr>
          <tr><td>Playback stalls</td><td class="num">\(session.stallCount)</td>
              <td>\(countBadge(session.stallCount, warnAt: 1, badAt: 3))</td>
              <td>Player reported waiting or stalled</td></tr>
          <tr><td>Rendition switches</td><td class="num">\(session.qualitySwitchCount)</td>
              <td>\(countBadge(session.qualitySwitchCount, warnAt: 3, badAt: 8))</td>
              <td>ABR changed quality level mid-play</td></tr>
        </table>

        <h2>Segment download time</h2>
        <table>
          <tr><th>Median</th><th>p95</th><th>Peak</th><th>Stream type</th><th>Last resolution</th></tr>
          <tr>
            <td class="num">\(msText(session.medianDownloadMs))</td>
            <td class="num">\(msText(session.p95DownloadMs))</td>
            <td class="num">\(msText(session.peakDownloadMs))</td>
            <td>\(session.isLive.map { $0 ? "Live" : "VOD" } ?? "—")</td>
            <td>\(escape(session.lastResolution ?? "—"))</td>
          </tr>
        </table>

        \(health.note.map { "<div class=\"callout\">\(escape($0))</div>" } ?? "")

        <div class="footer">
          <span>Generated by HLSMonitor · \(day.string(from: generatedAt)) \(time.string(from: generatedAt))</span>
          <span>\(session.consolidatedCount > 1 ? "Consolidated from \(session.consolidatedCount) sessions" : "Single session")</span>
        </div>
        </body></html>
        """
    }

    // MARK: - Helpers

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

    private static func countBadge(_ count: Int, warnAt: Int, badAt: Int) -> String {
        if count >= badAt { return "<span class=\"badge bad\">Poor</span>" }
        if count >= warnAt { return "<span class=\"badge warn\">Degraded</span>" }
        return "<span class=\"badge ok\">Clean</span>"
    }

    private static func healthAssessment(
        _ s: MonitoringSession
    ) -> (label: String, cssClass: String, note: String?) {
        let incidents = s.failureCount + s.gapCount + s.stallCount
        if s.failureCount >= 5 || s.gapCount >= 3 || s.stallCount >= 3 {
            return ("POOR", "poor",
                    "Repeated delivery problems were observed; viewers likely experienced interruptions.")
        }
        if incidents > 0 {
            return ("DEGRADED", "fair",
                    "Isolated delivery problems were observed but playback largely kept up.")
        }
        return ("HEALTHY", "good", nil)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
