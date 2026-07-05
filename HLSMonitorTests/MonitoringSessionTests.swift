//
//  MonitoringSessionTests.swift
//  HLSMonitorTests
//

import Foundation
import Testing
@testable import HLSMonitor

struct MonitoringSessionTests {

    private func session(
        url: String = "https://example.com/live.m3u8",
        start: Date,
        minutes: Double,
        segments: Int = 100,
        bytes: Int = 50_000_000,
        failures: Int = 0,
        gaps: Int = 0,
        stalls: Int = 0,
        switches: Int = 0,
        median: Double? = 300,
        p95: Double? = 900,
        peak: Double? = 1_200
    ) -> MonitoringSession {
        MonitoringSession(
            streamURL: url,
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            segmentCount: segments,
            totalBytes: bytes,
            failureCount: failures,
            gapCount: gaps,
            stallCount: stalls,
            qualitySwitchCount: switches,
            medianDownloadMs: median,
            p95DownloadMs: p95,
            peakDownloadMs: peak,
            averageBitrateMbps: 4.0,
            isLive: true,
            lastResolution: "1920×1080"
        )
    }

    @Test func consolidatingNothingReturnsNil() {
        #expect(MonitoringSession.consolidate([]) == nil)
    }

    @Test func consolidatingOneSessionIsIdentity() {
        let one = session(start: Date(timeIntervalSince1970: 1_000), minutes: 10)
        let merged = MonitoringSession.consolidate([one])
        #expect(merged?.segmentCount == 100)
        #expect(merged?.consolidatedCount == 1)
        #expect(merged?.monitoredSeconds == 600)
    }

    @Test func consolidationSumsCountsAndSpans() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first = session(start: base, minutes: 10, segments: 100,
                            bytes: 10_000_000, failures: 2, gaps: 1, stalls: 1, switches: 3)
        // One-hour gap between sessions must not count as monitored time.
        let second = session(start: base.addingTimeInterval(4_200), minutes: 20,
                             segments: 200, bytes: 30_000_000, failures: 1,
                             gaps: 0, stalls: 2, switches: 1)
        let merged = MonitoringSession.consolidate([first, second])
        #expect(merged?.segmentCount == 300)
        #expect(merged?.totalBytes == 40_000_000)
        #expect(merged?.failureCount == 3)
        #expect(merged?.gapCount == 1)
        #expect(merged?.stallCount == 3)
        #expect(merged?.qualitySwitchCount == 4)
        #expect(merged?.consolidatedCount == 2)
        #expect(merged?.monitoredSeconds == 1_800)
        #expect(merged?.startDate == first.startDate)
        #expect(merged?.endDate == second.endDate)
    }

    @Test func consolidationTakesWorstTailAndWeightsMedian() {
        let base = Date(timeIntervalSince1970: 2_000_000)
        let calm = session(start: base, minutes: 10, segments: 300,
                           median: 200, p95: 400, peak: 500)
        let rough = session(start: base.addingTimeInterval(900), minutes: 10,
                            segments: 100, median: 600, p95: 2_000, peak: 3_000)
        let merged = MonitoringSession.consolidate([calm, rough])
        #expect(merged?.p95DownloadMs == 2_000)
        #expect(merged?.peakDownloadMs == 3_000)
        // Weighted median: (200*300 + 600*100) / 400 = 300.
        #expect(merged?.medianDownloadMs == 300)
    }

    @Test func storeRoundTripsAndFiltersByDayAndURL() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = SessionStore(fileURL: file)
        let today = Date()
        let otherDay = today.addingTimeInterval(-3 * 24 * 3600)
        store.append(session(url: "https://a.example/x.m3u8", start: today, minutes: 5))
        store.append(session(url: "https://a.example/x.m3u8", start: today.addingTimeInterval(600), minutes: 5))
        store.append(session(url: "https://b.example/y.m3u8", start: today, minutes: 5))
        store.append(session(url: "https://a.example/x.m3u8", start: otherDay, minutes: 5))

        let reloaded = SessionStore(fileURL: file)
        #expect(reloaded.sessions.count == 4)
        let matching = reloaded.sessions(matching: "https://a.example/x.m3u8", sameDayAs: today)
        #expect(matching.count == 2)
        #expect(matching.first!.startDate < matching.last!.startDate)
    }

    @Test func storePrunesSessionsOlderThanSevenDays() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-prune-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = SessionStore(fileURL: file)
        store.append(session(start: Date().addingTimeInterval(-9 * 24 * 3600), minutes: 5))
        store.append(session(start: Date(), minutes: 5))
        #expect(store.sessions.count == 1)
    }

    @Test func reportHTMLContainsTheEssentials() {
        let one = session(
            url: "https://stream.example/hls/master.m3u8?token=<abc>",
            start: Date(timeIntervalSince1970: 1_750_000_000),
            minutes: 30, segments: 450, bytes: 500_000_000,
            failures: 2, gaps: 1, stalls: 1, switches: 4
        )
        let html = QualityReportHTML.page(for: one)
        #expect(html.contains("Stream Quality Report"))
        // URL is escaped, not raw.
        #expect(html.contains("token=&lt;abc&gt;"))
        #expect(!html.contains("token=<abc>"))
        #expect(html.contains("30m 00s"))
        #expect(html.contains("450"))
        #expect(html.contains("476.8 MB"))
        #expect(html.contains("DEGRADED"))
    }

    @Test func reportHealthVerdictReflectsIncidents() {
        let clean = session(start: Date(), minutes: 10)
        #expect(QualityReportHTML.page(for: clean).contains("HEALTHY"))
        let bad = session(start: Date(), minutes: 10, failures: 6)
        #expect(QualityReportHTML.page(for: bad).contains("POOR"))
    }
}
