//
//  FieldMetricsDigest+MetricKit.swift
//  OpenHikes
//
//  The one place MetricKit's object graph is read.
//
//  Split from `FieldMetricsDigest.swift` for a reason that is not tidiness: an
//  `MXMetricPayload` has no public initializer and no way in from JSON, so a
//  test cannot construct one. Anything on this side of the file boundary is
//  therefore unreachable from the test bundle by construction, and the split
//  keeps that unreachable part as thin as it can be — every accessor here is a
//  field read, a unit conversion or a `nil` check, and every derivation worth
//  asserting lives next door where a test can build the input itself.
//

import Foundation
import MetricKit

nonisolated extension HistogramSummary {
    /// MetricKit hands buckets out through an `NSEnumerator`, which loses the
    /// histogram's unit generic on the way into Swift. `unit` is therefore
    /// passed in by the caller, who does know it, and every bucket is
    /// converted to it — otherwise a duration histogram reported in seconds
    /// and one reported in milliseconds would produce the same numbers with
    /// different meanings.
    init<UnitType: Dimension>(_ histogram: MXHistogram<UnitType>, convertedTo unit: UnitType) {
        var buckets: [Bucket] = []
        buckets.reserveCapacity(histogram.totalBucketCount)
        for case let bucket as MXHistogramBucket<UnitType> in histogram.bucketEnumerator {
            buckets.append(
                Bucket(
                    start: bucket.bucketStart.converted(to: unit).value,
                    end: bucket.bucketEnd.converted(to: unit).value,
                    count: Int(bucket.bucketCount)
                )
            )
        }
        self.init(buckets: buckets.sorted { $0.start < $1.start })
    }

    /// `nil` rather than an empty summary when the payload carried no samples,
    /// so the UI can say "not reported in this period" rather than draw a row
    /// of dashes that looks like a measured zero.
    static func make<UnitType: Dimension>(
        _ histogram: MXHistogram<UnitType>?,
        convertedTo unit: UnitType
    ) -> Self? {
        guard let histogram else { return nil }
        let summary = Self(histogram, convertedTo: unit)
        return summary.isEmpty ? nil : summary
    }
}

nonisolated extension LocationAccuracyBreakdown {
    init(_ metric: MXLocationActivityMetric) {
        self.init(
            bestSeconds: metric.cumulativeBestAccuracyTime.seconds,
            bestForNavigationSeconds: metric.cumulativeBestAccuracyForNavigationTime.seconds,
            nearestTenMetersSeconds: metric.cumulativeNearestTenMetersAccuracyTime.seconds,
            hundredMetersSeconds: metric.cumulativeHundredMetersAccuracyTime.seconds,
            kilometerSeconds: metric.cumulativeKilometerAccuracyTime.seconds,
            threeKilometersSeconds: metric.cumulativeThreeKilometersAccuracyTime.seconds
        )
    }
}

nonisolated extension ExitBreakdown {
    init(_ metric: MXAppExitMetric) {
        let background = metric.backgroundExitData
        let foreground = metric.foregroundExitData
        self.init(
            backgroundMemoryLimitExits: background.cumulativeMemoryResourceLimitExitCount,
            backgroundMemoryPressureExits: background.cumulativeMemoryPressureExitCount,
            backgroundCPULimitExits: background.cumulativeCPUResourceLimitExitCount,
            backgroundWatchdogExits: background.cumulativeAppWatchdogExitCount,
            backgroundTaskTimeoutExits: background.cumulativeBackgroundTaskAssertionTimeoutExitCount,
            backgroundLockedFileExits: background.cumulativeSuspendedWithLockedFileExitCount,
            backgroundNormalExits: background.cumulativeNormalAppExitCount,
            foregroundWatchdogExits: foreground.cumulativeAppWatchdogExitCount,
            foregroundMemoryLimitExits: foreground.cumulativeMemoryResourceLimitExitCount,
            foregroundNormalExits: foreground.cumulativeNormalAppExitCount
        )
    }
}

nonisolated extension SignpostDigest {
    init(_ metric: MXSignpostMetric) {
        let interval = metric.signpostIntervalData
        self.init(
            name: metric.signpostName,
            category: metric.signpostCategory,
            count: metric.totalCount,
            duration: interval.map { data in
                HistogramSummary(data.histogrammedSignpostDuration, convertedTo: UnitDuration.milliseconds)
            },
            cpuSeconds: interval?.cumulativeCPUTime?.seconds,
            averageMemoryBytes: interval?.averageMemory?.averageMeasurement.bytes,
            logicalWriteBytes: interval?.cumulativeLogicalWrites?.bytes,
            hitchTimeRatio: interval?.cumulativeHitchTimeRatio?.ratio
        )
    }
}

nonisolated extension FieldMetricsDigest {
    init(_ payload: MXMetricPayload) {
        self.init(
            foregroundSeconds: payload.applicationTimeMetrics?.cumulativeForegroundTime.seconds,
            backgroundSeconds: payload.applicationTimeMetrics?.cumulativeBackgroundTime.seconds,
            backgroundLocationSeconds: payload.applicationTimeMetrics?
                .cumulativeBackgroundLocationTime.seconds,
            cpuSeconds: payload.cpuMetrics?.cumulativeCPUTime.seconds,
            gpuSeconds: payload.gpuMetrics?.cumulativeGPUTime.seconds,
            locationAccuracy: payload.locationActivityMetrics.map(LocationAccuracyBreakdown.init),
            timeToFirstDraw: .make(
                payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw,
                convertedTo: UnitDuration.milliseconds
            ),
            optimizedTimeToFirstDraw: .make(
                payload.applicationLaunchMetrics?.histogrammedOptimizedTimeToFirstDraw,
                convertedTo: UnitDuration.milliseconds
            ),
            extendedLaunch: .make(
                payload.applicationLaunchMetrics?.histogrammedExtendedLaunch,
                convertedTo: UnitDuration.milliseconds
            ),
            resumeTime: .make(
                payload.applicationLaunchMetrics?.histogrammedApplicationResumeTime,
                convertedTo: UnitDuration.milliseconds
            ),
            applicationHangTime: .make(
                payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime,
                convertedTo: UnitDuration.milliseconds
            ),
            // `hitchTimeRatio` covers every animation rather than only scrolling
            // and is new in iOS 26. Both are kept: the app's deployment target
            // guarantees the new one exists, but the two are not the same
            // measurement and a scroll regression is worth seeing on its own.
            hitchTimeRatio: payload.animationMetrics?.hitchTimeRatio.ratio,
            scrollHitchTimeRatio: payload.animationMetrics?.scrollHitchTimeRatio.ratio,
            cellularConditionBars: .make(
                payload.cellularConditionMetrics?.histogrammedCellularConditionTime,
                convertedTo: MXUnitSignalBars.bars
            ),
            logicalWriteBytes: payload.diskIOMetrics?.cumulativeLogicalWrites.bytes,
            binaryFileBytes: payload.diskSpaceUsageMetrics?.totalBinaryFileSize.bytes,
            dataFileBytes: payload.diskSpaceUsageMetrics?.totalDataFileSize.bytes,
            cacheFolderBytes: payload.diskSpaceUsageMetrics?.totalCacheFolderSize.bytes,
            totalDiskUsedBytes: payload.diskSpaceUsageMetrics?.totalDiskSpaceUsedSize.bytes,
            averageSuspendedMemoryBytes: payload.memoryMetrics?
                .averageSuspendedMemory.averageMeasurement.bytes,
            peakMemoryBytes: payload.memoryMetrics?.peakMemoryUsage.bytes,
            exits: payload.applicationExitMetrics.map(ExitBreakdown.init),
            signposts: (payload.signpostMetrics ?? [])
                .map(SignpostDigest.init)
                .sorted { $0.id < $1.id }
        )
    }
}

nonisolated extension FieldDiagnosticDigest {
    /// Flattens a diagnostic payload into one entry per diagnostic.
    ///
    /// Call stacks are carried as the framework's own JSON rather than decoded:
    /// the app never inspects a frame, it only ever hands the whole thing to
    /// somebody who will symbolicate it elsewhere.
    static func entries(in payload: MXDiagnosticPayload) -> [Self] {
        var entries: [Self] = []
        for diagnostic in payload.crashDiagnostics ?? [] {
            entries.append(
                Self(
                    kind: .crash,
                    reason: diagnostic.terminationReason
                        ?? diagnostic.exceptionReason?.exceptionName,
                    appVersion: diagnostic.applicationVersion,
                    callStackJSON: diagnostic.callStackTree.jsonRepresentation()
                )
            )
        }
        for diagnostic in payload.hangDiagnostics ?? [] {
            entries.append(
                Self(
                    kind: .hang,
                    seconds: diagnostic.hangDuration.seconds,
                    appVersion: diagnostic.applicationVersion,
                    callStackJSON: diagnostic.callStackTree.jsonRepresentation()
                )
            )
        }
        for diagnostic in payload.appLaunchDiagnostics ?? [] {
            entries.append(
                Self(
                    kind: .appLaunch,
                    seconds: diagnostic.launchDuration.seconds,
                    appVersion: diagnostic.applicationVersion,
                    callStackJSON: diagnostic.callStackTree.jsonRepresentation()
                )
            )
        }
        for diagnostic in payload.diskWriteExceptionDiagnostics ?? [] {
            entries.append(
                Self(
                    kind: .diskWriteException,
                    bytes: diagnostic.totalWritesCaused.bytes,
                    appVersion: diagnostic.applicationVersion,
                    callStackJSON: diagnostic.callStackTree.jsonRepresentation()
                )
            )
        }
        for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
            entries.append(
                Self(
                    kind: .cpuException,
                    seconds: diagnostic.totalCPUTime.seconds,
                    appVersion: diagnostic.applicationVersion,
                    callStackJSON: diagnostic.callStackTree.jsonRepresentation()
                )
            )
        }
        return entries
    }
}

// MARK: - Measurement conversions

/// MetricKit dimensions its measurements in whatever unit it pleases, and a
/// caller that reads `.value` without converting first will silently be out by
/// a factor of a thousand when a future OS reports the same field in
/// milliseconds or kilobytes. These exist so no call site above ever reads
/// `.value` on a dimensioned quantity.
nonisolated private extension Measurement where UnitType == UnitDuration {
    var seconds: Double { converted(to: .seconds).value }
}

nonisolated private extension Measurement where UnitType == UnitInformationStorage {
    var bytes: Double { converted(to: .bytes).value }
}

/// A dimensionless quantity — a hitch time ratio. There is nothing to convert,
/// so this exists only to make that explicit at the call site rather than
/// leaving a bare `.value` that looks like an oversight.
nonisolated private extension Measurement where UnitType == Unit {
    var ratio: Double { value }
}
