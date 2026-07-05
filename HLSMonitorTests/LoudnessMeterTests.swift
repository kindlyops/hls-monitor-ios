//
//  LoudnessMeterTests.swift
//  HLSMonitorTests
//

import Foundation
import Testing
@testable import HLSMonitor

struct LoudnessMeterTests {

    private func sine(
        frequency: Double, amplitude: Double, seconds: Double, rate: Double
    ) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    @Test func emptyMeterReportsNothing() {
        let meter = LoudnessMeter()
        let levels = meter.levels
        #expect(levels.momentary == nil)
        #expect(levels.shortTerm == nil)
        #expect(levels.integrated == nil)
        #expect(levels.peakDbfs == nil)
    }

    @Test func silenceReportsNilLoudness() {
        let meter = LoudnessMeter()
        meter.process(channels: [[Float](repeating: 0, count: 48_000)], sampleRate: 48_000)
        let levels = meter.levels
        #expect(levels.momentary == nil)
        #expect(levels.integrated == nil)
        #expect(levels.peakDbfs == nil)
    }

    @Test func stereoSineMatchesReferenceLoudness() {
        // BS.1770 calibration: a 997 Hz full-scale sine in one channel reads
        // -3.01 LKFS, so a -20 dBFS sine reads -23.01 mono and -20.00 when
        // present in both stereo channels.
        let meter = LoudnessMeter()
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 48_000)
        meter.process(channels: [tone, tone], sampleRate: 48_000)
        let levels = meter.levels
        #expect(levels.peakDbfs != nil && abs(levels.peakDbfs! - -20.0) < 0.05)
        #expect(levels.momentary != nil && abs(levels.momentary! - -20.0) < 0.1)
        #expect(levels.shortTerm != nil && abs(levels.shortTerm! - -20.0) < 0.1)
        #expect(levels.integrated != nil && abs(levels.integrated! - -20.0) < 0.1)
    }

    @Test func monoSineReadsThreeLowerThanStereo() {
        let meter = LoudnessMeter()
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 48_000)
        meter.process(channels: [tone], sampleRate: 48_000)
        let mono = meter.levels.momentary
        #expect(mono != nil && abs(mono! - -23.01) < 0.1)
    }

    @Test func sampleRateChangesAgreeWithinTolerance() {
        let meter48 = LoudnessMeter()
        meter48.process(
            channels: [sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 48_000)],
            sampleRate: 48_000
        )
        let meter44 = LoudnessMeter()
        meter44.process(
            channels: [sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: 44_100)],
            sampleRate: 44_100
        )
        let a = meter48.levels.shortTerm
        let b = meter44.levels.shortTerm
        #expect(a != nil && b != nil && abs(a! - b!) < 0.2)
    }

    @Test func gatingExcludesLongQuietPassages() {
        // 5s of tone then 20s of near-silence: an ungated mean would sink by
        // ~7 dB; the gated integrated value must stay near the tone.
        let meter = LoudnessMeter()
        let rate = 48_000.0
        meter.process(
            channels: [sine(frequency: 997, amplitude: 0.1, seconds: 5, rate: rate)],
            sampleRate: rate
        )
        meter.process(
            channels: [sine(frequency: 997, amplitude: 0.0001, seconds: 20, rate: rate)],
            sampleRate: rate
        )
        let integrated = meter.levels.integrated
        #expect(integrated != nil && abs(integrated! - -23.01) < 1.0)
    }

    @Test func buffersSplitAcrossCallsMatchOneCall() {
        let tone = sine(frequency: 997, amplitude: 0.1, seconds: 4, rate: 48_000)
        let whole = LoudnessMeter()
        whole.process(channels: [tone], sampleRate: 48_000)
        let chunked = LoudnessMeter()
        for chunk in stride(from: 0, to: tone.count, by: 1_024) {
            let end = min(chunk + 1_024, tone.count)
            chunked.process(channels: [Array(tone[chunk..<end])], sampleRate: 48_000)
        }
        let a = whole.levels.shortTerm
        let b = chunked.levels.shortTerm
        #expect(a != nil && b != nil && abs(a! - b!) < 0.01)
    }
}
