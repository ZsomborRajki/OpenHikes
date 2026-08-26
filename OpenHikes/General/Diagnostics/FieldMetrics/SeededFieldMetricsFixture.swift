//
//  SeededFieldMetricsFixture.swift
//  OpenHikes
//
//  Device reports for a device that never files any.
//
//  MetricKit delivers nothing on a Simulator: `mxSignpost` attaches the
//  literal `NO_METRICS` there, no payload is ever handed to
//  `MXMetricManagerSubscriber`, and `FieldMetricsStore` therefore stays empty
//  for the entire life of an automated run. That left Settings ▸ Device
//  Reports permanently in its empty state, and everything downstream of a row
//  — the report screen, the export screen, the share sheet, the delete button
//  — unreachable by any test at all. Four screens whose only job is to say
//  what a number means, and nothing checking that they say anything.
//
//  This closes that from the app side, behind `--ui-test-seed-metrics=N`, and
//  it fakes exactly one thing: the numbers. The reports are written by the
//  real ``FieldMetricsStore`` into the real per-launch directory, encoded and
//  decoded by the shipping `Codable` conformances, and subject to the same
//  retention limits — so a test that opens the screen afterwards is reading
//  the shipping path.
//
//  The values are chosen to be *recognisable* rather than plausible. Every
//  optional the screen can draw is filled, because a row that draws "Not
//  reported" is indistinguishable from a row that draws nothing at all, and
//  the difference is the whole point of the screen.
//

import Foundation

#if DEBUG
nonisolated enum SeededFieldMetricsFixture {
    /// A day per report, counting back from the launch. MetricKit periods are
    /// daily, and dating them apart is what makes the list sort visibly.
    private static let periodSeconds: TimeInterval = 24 * 60 * 60
    private static let foregroundSeconds = 3600.0
    private static let backgroundSeconds = 18_000.0
    private static let backgroundLocationSeconds = 16_200.0
    private static let cpuSeconds = 420.0
    private static let gpuSeconds = 63.0
    private static let hitchTimeRatio = 0.0021
    private static let scrollHitchTimeRatio = 0.0034
    private static let logicalWriteBytes = 268_435_456.0
    private static let binaryFileBytes = 41_943_040.0
    private static let dataFileBytes = 335_544_320.0
    private static let cacheFolderBytes = 134_217_728.0
    private static let totalDiskUsedBytes = 511_705_088.0
    private static let averageSuspendedMemoryBytes = 62_914_560.0
    private static let peakMemoryBytes = 176_160_768.0
    private static let hangMilliseconds = 310.0
    private static let diagnosticHangSeconds = 1.42
    private static let recordingSpanCPUSeconds = 310.0
    private static let recordingSpanMemoryBytes = 88_080_384.0
    private static let recordingSpanWriteBytes = 201_326_592.0
    private static let downloadSpanCPUSeconds = 22.0
    private static let downloadSpanWriteBytes = 67_108_864.0
    private static let recordingSpanMilliseconds = 5_400_000.0
    private static let downloadSpanMilliseconds = 48_000.0
    private static let bestFixSeconds = 1200.0
    private static let tenMeterFixSeconds = 12_600.0
    private static let hundredMeterFixSeconds = 2400.0
    /// The typical value each histogram is built around; the two longer
    /// buckets are derived from it below.
    ///
    /// Milliseconds, not seconds: every duration histogram in
    /// ``FieldMetricsDigest`` is stored in milliseconds — that is the unit
    /// ``HistogramSummary/init(_:convertedTo:)`` is handed for all of them —
    /// and the screen renders them with no fractional digits, so a value
    /// expressed in seconds would draw as "0 ms".
    private static let firstDrawMilliseconds = 240.0
    private static let optimizedFirstDrawMilliseconds = 190.0
    private static let extendedLaunchMilliseconds = 410.0
    private static let resumeMilliseconds = 110.0
    private static let cellularBars = 1.0

    /// Writes `count` reports, newest first.
    ///
    /// The first is a metrics digest and the second — when more than one is
    /// asked for — is a diagnostics report, because those are the two shapes
    /// the list draws and a scenario that only ever sees one of them proves
    /// half of what it looks like it proves.
    static func seed(
        count: Int,
        store: FieldMetricsStore = .shared,
        now: Date = .now
    ) async {
        guard count > 0 else { return }
        for index in 0..<count {
            let end = now.addingTimeInterval(-periodSeconds * Double(index))
            await store.save(
                report(
                    index: index,
                    periodStart: end.addingTimeInterval(-periodSeconds),
                    periodEnd: end
                )
            )
        }
    }

    private static func report(
        index: Int,
        periodStart: Date,
        periodEnd: Date
    ) -> FieldMetricsReport {
        FieldMetricsReport(
            receivedAt: periodEnd,
            periodStart: periodStart,
            periodEnd: periodEnd,
            appVersion: "1.0",
            content: index == 1 ? .diagnostics(diagnostics()) : .metrics(digest()),
            appBuild: "1",
            osVersion: "iPhone OS 26.5 (99A999)",
            deviceType: "iPhone18,1",
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isTestFlight: false
        )
    }

    private static func digest() -> FieldMetricsDigest {
        FieldMetricsDigest(
            foregroundSeconds: foregroundSeconds,
            backgroundSeconds: backgroundSeconds,
            backgroundLocationSeconds: backgroundLocationSeconds,
            cpuSeconds: cpuSeconds,
            gpuSeconds: gpuSeconds,
            locationAccuracy: LocationAccuracyBreakdown(
                bestSeconds: bestFixSeconds,
                bestForNavigationSeconds: 0,
                nearestTenMetersSeconds: tenMeterFixSeconds,
                hundredMetersSeconds: hundredMeterFixSeconds,
                kilometerSeconds: 0,
                threeKilometersSeconds: 0
            ),
            timeToFirstDraw: histogram(around: firstDrawMilliseconds),
            optimizedTimeToFirstDraw: histogram(around: optimizedFirstDrawMilliseconds),
            extendedLaunch: histogram(around: extendedLaunchMilliseconds),
            resumeTime: histogram(around: resumeMilliseconds),
            applicationHangTime: histogram(around: hangMilliseconds),
            hitchTimeRatio: hitchTimeRatio,
            scrollHitchTimeRatio: scrollHitchTimeRatio,
            cellularConditionBars: histogram(around: cellularBars),
            logicalWriteBytes: logicalWriteBytes,
            binaryFileBytes: binaryFileBytes,
            dataFileBytes: dataFileBytes,
            cacheFolderBytes: cacheFolderBytes,
            totalDiskUsedBytes: totalDiskUsedBytes,
            averageSuspendedMemoryBytes: averageSuspendedMemoryBytes,
            peakMemoryBytes: peakMemoryBytes,
            exits: exits(),
            signposts: signposts()
        )
    }

    /// One of each kind the screen distinguishes, because "no unexpected
    /// exits" and "this payload carried no exit data" are drawn differently
    /// and a fixture of all zeroes would only ever show one of them.
    private static func exits() -> ExitBreakdown {
        ExitBreakdown(
            backgroundMemoryLimitExits: 0,
            backgroundMemoryPressureExits: 1,
            backgroundCPULimitExits: 0,
            backgroundWatchdogExits: 0,
            backgroundTaskTimeoutExits: 0,
            backgroundLockedFileExits: 0,
            backgroundNormalExits: 7,
            foregroundWatchdogExits: 0,
            foregroundMemoryLimitExits: 0,
            foregroundNormalExits: 3
        )
    }

    /// The app's own two spans, named through ``FieldSignpost`` rather than
    /// as strings — a fixture that spelled them itself would keep passing
    /// after a rename that emptied the real screen.
    private static func signposts() -> [SignpostDigest] {
        [
            SignpostDigest(
                name: FieldSignpost.Span.recordingSession.rawValue,
                category: FieldSignpost.category,
                count: 2,
                duration: histogram(around: recordingSpanMilliseconds),
                cpuSeconds: recordingSpanCPUSeconds,
                averageMemoryBytes: recordingSpanMemoryBytes,
                logicalWriteBytes: recordingSpanWriteBytes
            ),
            SignpostDigest(
                name: FieldSignpost.Span.offlineDownload.rawValue,
                category: FieldSignpost.category,
                count: 1,
                duration: histogram(around: downloadSpanMilliseconds),
                cpuSeconds: downloadSpanCPUSeconds,
                logicalWriteBytes: downloadSpanWriteBytes
            ),
        ]
    }

    private static func diagnostics() -> [FieldDiagnosticDigest] {
        [
            FieldDiagnosticDigest(
                kind: .hang,
                seconds: diagnosticHangSeconds,
                appVersion: "1.0"
            ),
            FieldDiagnosticDigest(
                kind: .diskWriteException,
                bytes: logicalWriteBytes,
                appVersion: "1.0"
            ),
        ]
    }

    /// Three buckets around a typical value, which is enough for every
    /// quantile the screen reads.
    ///
    /// Weighted towards the fast bucket and thinning out, because a flat
    /// histogram makes a median and a 95th percentile the same number — and
    /// telling those two apart is the only reason the screen draws both.
    private static func histogram(around typical: Double) -> HistogramSummary {
        let median = typical * medianSpread
        let tail = typical * tailSpread
        return HistogramSummary(
            buckets: [
                HistogramSummary.Bucket(start: 0, end: typical, count: 6),
                HistogramSummary.Bucket(start: typical, end: median, count: 3),
                HistogramSummary.Bucket(start: median, end: tail, count: 1),
            ]
        )
    }

    private static let medianSpread = 1.6
    private static let tailSpread = 2.6
}
#endif
