//
//  FieldMetricsDigestTests.swift
//  OpenHikesTests
//
//  What can and cannot be tested about the MetricKit integration, and why the
//  line falls where it does.
//
//  `MXMetricPayload` has no public initializer and no way to be synthesised —
//  the only way to obtain one is to be handed it by the system, which happens
//  on a device, once a day, in a Release build. That is why the adapter layer
//  in `FieldMetricsDigest+MetricKit.swift` is kept as thin as it is: it does
//  nothing but read fields and hand them across. Every judgement the app makes
//  about those numbers — the quantile walk, the shares, which exits count as
//  unexpected — lives in `FieldMetricsDigest.swift`, which knows nothing about
//  MetricKit and is therefore entirely testable from a struct literal.
//
//  These tests are the reason that split exists. Without it the interesting
//  arithmetic would be sealed behind a type nobody can construct.
//

@testable import OpenHikes
import Testing

@Suite("Field metrics digest")
nonisolated struct FieldMetricsDigestTests {
    private static func histogram(_ buckets: [(Double, Double, Int)]) -> HistogramSummary {
        HistogramSummary(
            buckets: buckets.map { start, end, count in
                HistogramSummary.Bucket(start: start, end: end, count: count)
            }
        )
    }

    // MARK: - Histograms

    @Test("an empty histogram reports nothing rather than zero")
    func emptyHistogram() {
        let empty = HistogramSummary()
        #expect(empty.isEmpty)
        #expect(empty.sampleCount == 0)
        #expect(empty.medianUpperBound == nil)
        #expect(empty.p90UpperBound == nil)
        #expect(empty.worstUpperBound == nil)
    }

    @Test("a histogram of empty buckets is still empty")
    func zeroCountBuckets() {
        let summary = Self.histogram([(0, 100, 0), (100, 200, 0)])
        #expect(summary.isEmpty)
        #expect(summary.medianUpperBound == nil)
        #expect(summary.worstUpperBound == nil)
    }

    @Test("a single bucket answers every quantile with its own upper edge")
    func singleBucket() {
        let summary = Self.histogram([(0, 250, 40)])
        #expect(summary.sampleCount == 40)
        #expect(summary.medianUpperBound == 250)
        #expect(summary.p90UpperBound == 250)
        #expect(summary.worstUpperBound == 250)
    }

    @Test("a quantile lands in the bucket that contains it")
    func quantileWalk() {
        // 10 + 10 + 10 + 70 = 100 samples.
        let summary = Self.histogram([
            (0, 100, 10),
            (100, 200, 10),
            (200, 300, 10),
            (300, 400, 70),
        ])

        #expect(summary.sampleCount == 100)
        // The 10th sample is the last one in the first bucket.
        #expect(summary.upperBound(atQuantile: 0.1) == 100)
        // The 50th is inside the fourth.
        #expect(summary.medianUpperBound == 400)
        #expect(summary.p90UpperBound == 400)
    }

    @Test("quantiles outside 0...1 are clamped rather than walking off the end")
    func quantileClamping() {
        let summary = Self.histogram([(0, 100, 5), (100, 200, 5)])
        #expect(summary.upperBound(atQuantile: -3) == 100)
        #expect(summary.upperBound(atQuantile: 4) == 200)
    }

    @Test("the worst case skips trailing empty buckets")
    func worstCaseIgnoresEmptyTail() {
        // MetricKit pads with empty buckets. Reporting the pad as the worst
        // observed latency would overstate it by a whole bucket width or more.
        let summary = Self.histogram([(0, 100, 3), (100, 200, 2), (200, 300, 0)])
        #expect(summary.worstUpperBound == 200)
        #expect(summary.medianUpperBound == 100)
    }

    // MARK: - Location accuracy

    @Test("no location time at all reports no conserving share")
    func conservingShareWithoutSamples() {
        // This is the distinction the whole formatter layer exists to keep.
        // "The app never used GPS" and "the app used GPS and never conserved"
        // are opposite facts and both would render as 0% if this returned zero.
        let breakdown = LocationAccuracyBreakdown()
        #expect(breakdown.totalSeconds == 0)
        #expect(breakdown.conservingShare == nil)
    }

    @Test("the conserving share is the coarse accuracy classes over the whole time")
    func conservingShare() {
        // The assertion Energy Finding E1 is waiting on: how much of a real
        // walk's GPS duty actually ran in the conserving profile.
        let breakdown = LocationAccuracyBreakdown(
            bestSeconds: 300,
            bestForNavigationSeconds: 100,
            nearestTenMetersSeconds: 400,
            hundredMetersSeconds: 150,
            kilometerSeconds: 50,
            threeKilometersSeconds: 0
        )

        #expect(breakdown.totalSeconds == 1000)
        // 400 + 150 + 50 + 0 = 600 of 1000.
        #expect(breakdown.conservingShare == 0.6)
    }

    @Test("a wholly conserving period reports the whole of it")
    func fullyConserving() {
        let breakdown = LocationAccuracyBreakdown(nearestTenMetersSeconds: 900)
        #expect(breakdown.conservingShare == 1)
    }

    // MARK: - Exits

    @Test("a normal exit is not an unexpected one")
    func normalExitsAreNotCounted() {
        // A hiker who swipes the app away has not lost anything. Counting that
        // alongside a jetsam would make the one number worth watching useless.
        let exits = ExitBreakdown(
            backgroundNormalExits: 30,
            foregroundNormalExits: 12
        )
        #expect(exits.unexpectedTotal == 0)
    }

    @Test("every abnormal termination is counted once")
    func unexpectedExitsAreCounted() {
        let exits = ExitBreakdown(
            backgroundMemoryLimitExits: 1,
            backgroundMemoryPressureExits: 2,
            backgroundCPULimitExits: 3,
            backgroundWatchdogExits: 4,
            backgroundTaskTimeoutExits: 5,
            backgroundLockedFileExits: 6,
            backgroundNormalExits: 100,
            foregroundWatchdogExits: 7,
            foregroundMemoryLimitExits: 8,
            foregroundNormalExits: 200
        )
        #expect(exits.unexpectedTotal == 36)
    }

    // MARK: - Derived rates

    @Test("CPU per active hour needs some active time to divide by")
    func cpuRateWithoutActiveTime() {
        let digest = FieldMetricsDigest(cpuSeconds: 120)
        #expect(digest.cpuSecondsPerActiveHour == nil)
    }

    @Test("CPU per active hour normalises across foreground and background")
    func cpuRate() {
        // The number that makes two payloads from different-length days
        // comparable at all, which is the point of collecting them daily.
        let digest = FieldMetricsDigest(
            foregroundSeconds: 1800,
            backgroundSeconds: 1800,
            cpuSeconds: 180
        )
        #expect(digest.cpuSecondsPerActiveHour == 180)
    }

    @Test("CPU per active hour is nil when the payload carried no CPU time")
    func cpuRateWithoutCPU() {
        let digest = FieldMetricsDigest(foregroundSeconds: 3600)
        #expect(digest.cpuSecondsPerActiveHour == nil)
    }

    @Test("the pocket share is background GPS against the app's whole lifetime")
    func backgroundLocationShare() {
        // "Time in a pocket": screen off, recording running. Finding 4's
        // 0.9% duty cycle is a Simulator figure; this is the field twin.
        let digest = FieldMetricsDigest(
            backgroundSeconds: 4000,
            backgroundLocationSeconds: 3000
        )
        #expect(digest.backgroundLocationShare == 0.75)
    }

    @Test("the pocket share is absent when the app was never alive at all")
    func backgroundLocationShareWithoutBackground() {
        let digest = FieldMetricsDigest(backgroundLocationSeconds: 10)
        #expect(digest.backgroundLocationShare == nil)
    }

    // MARK: - Signposts

    @Test("a signpost's CPU cost is amortised over its occurrences")
    func signpostCPUPerOccurrence() {
        let signpost = SignpostDigest(
            name: "RecordingSession",
            category: "Hiking",
            count: 4,
            cpuSeconds: 60
        )
        #expect(signpost.cpuSecondsPerOccurrence == 15)
    }

    @Test("a signpost with no occurrences reports no per-occurrence cost")
    func signpostCPUWithoutOccurrences() {
        let signpost = SignpostDigest(name: "HikeImport", category: "Hiking", count: 0, cpuSeconds: 5)
        #expect(signpost.cpuSecondsPerOccurrence == nil)
    }

    @Test("the measured spans stay few and deliberate")
    func spanBudget() {
        // A tripwire, not a fact about the number four. Apple caps how many
        // MetricKit signposts it will process per period and drops the rest
        // silently, so a fifth span added without thinking does not fail — it
        // quietly costs the other four their telemetry. Adding one here is
        // fine; adding one without noticing is not.
        #expect(FieldSignpost.Span.allCases.count == 4)
        #expect(Set(FieldSignpost.Span.allCases.map(\.rawValue)).count == 4)
    }
}
