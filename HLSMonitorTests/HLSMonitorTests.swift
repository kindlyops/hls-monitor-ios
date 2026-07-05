//
//  HLSMonitorTests.swift
//  HLSMonitorTests
//
//  Created by Neel Makhecha on 9/5/25.
//

import Foundation
import Testing
@testable import HLSMonitor

struct SegmentTrackerPercentileTests {

    private func tracker(downloadTimes: [Double]) -> SegmentTracker {
        var tracker = SegmentTracker()
        tracker.recentSamples = downloadTimes.map {
            SegmentSample(downloadMs: $0, bytes: 0, date: Date(timeIntervalSince1970: 0))
        }
        return tracker
    }

    @Test func percentileOfEmptyWindowIsNil() {
        #expect(tracker(downloadTimes: []).downloadPercentileMs(0.5) == nil)
    }

    @Test func percentileOfSingleSampleIsThatSample() {
        let tracker = tracker(downloadTimes: [250])
        #expect(tracker.downloadPercentileMs(0.0) == 250)
        #expect(tracker.downloadPercentileMs(0.5) == 250)
        #expect(tracker.downloadPercentileMs(1.0) == 250)
    }

    @Test func medianInterpolatesBetweenMiddleValues() {
        let tracker = tracker(downloadTimes: [100, 300, 200, 400])
        #expect(tracker.downloadPercentileMs(0.5) == 250)
    }

    @Test func medianIgnoresSampleOrder() {
        let tracker = tracker(downloadTimes: [400, 100, 300, 200, 500])
        #expect(tracker.downloadPercentileMs(0.5) == 300)
    }

    @Test func extremesMatchMinAndMax() {
        let tracker = tracker(downloadTimes: [80, 20, 60, 40])
        #expect(tracker.downloadPercentileMs(0.0) == 20)
        #expect(tracker.downloadPercentileMs(1.0) == 80)
        #expect(tracker.downloadPercentileMs(1.0) == tracker.peakDownloadMs)
    }

    @Test func p95SurfacesTheTailTheMeanWouldHide() {
        // 19 fast segments and one 3-second stall: the mean would sit near
        // 240ms, but p95 must land close to the slow outlier.
        let times = Array(repeating: 100.0, count: 19) + [3000.0]
        let p95 = tracker(downloadTimes: times).downloadPercentileMs(0.95)
        #expect(p95 != nil)
        #expect(p95! > 100)
        #expect(p95!.isFinite)
        // rank = 0.95 * 19 = 18.05 → interpolate between 100 and 3000.
        #expect(abs(p95! - (100 + 0.05 * 2900)) < 0.0001)
    }
}
