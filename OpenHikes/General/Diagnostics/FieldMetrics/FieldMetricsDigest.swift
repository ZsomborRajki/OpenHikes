//
//  FieldMetricsDigest.swift
//  OpenHikes
//
//  The subset of a MetricKit payload this app has an actual question about,
//  reduced to plain values.
//
//  Everything else in `Diagnostics/` measures a *simulator*, in *Debug*, on a
//  *synthetic* route, before a change is merged. That is the right shape for a
//  budget you want to fail a pull request, and it is the wrong shape — in
//  fact it is structurally incapable — for two of the gaps `PERFORMANCE.md`
//  lists under *Blind spots*:
//
//  * A real hike-length recording's energy. Every energy number that harness
//    produces extrapolates from a three-fix scenario, and the walk that would
//    settle whether the per-fix cost is flat has not been taken.
//  * Whether `RecordingEnergyPolicy`'s conserving profile is ever reached. A
//    simulator's thermal state never leaves `.nominal`, so that profile has
//    never been exercised outside unit tests.
//
//  MetricKit answers both, from the only place they can be answered: a real
//  phone, in Release, on a real walk. It is the opposite instrument to the
//  rest of this folder in every dimension — aggregated rather than per-event,
//  daily rather than immediate, field rather than lab — which is why it
//  *extends* the harness and replaces nothing in it.
//
//  This file is deliberately free of MetricKit imports. The extraction lives
//  next door in `FieldMetricsDigest+MetricKit.swift`; the arithmetic and the
//  interpretation live here, where a test can reach them — an `MXMetricPayload`
//  cannot be constructed by a test at all, so anything worth asserting has to
//  be on this side of the line.
//

import Foundation

// MARK: - Histogram

/// A MetricKit histogram, flattened.
///
/// MetricKit reports distributions as buckets rather than as samples, so no
/// exact percentile exists to be read out. Every statistic below is therefore
/// an *upper bound* — the far edge of the bucket the percentile falls in —
/// and named so that a reader cannot mistake it for a measured value.
nonisolated struct HistogramSummary: Codable, Sendable, Equatable {
    struct Bucket: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var count: Int
    }

    /// The quantiles the app reads. Named because a bare `0.5` in the middle
    /// of a percentile calculation reads as arithmetic rather than as a
    /// choice, and both of these are choices.
    private static let medianQuantile = 0.5
    private static let p90Quantile = 0.9
    private static let quantileRange = 0.0...1.0

    /// Ascending by `start`, as MetricKit enumerates them.
    var buckets: [Bucket]

    init(buckets: [Bucket] = []) {
        self.buckets = buckets
    }

    var sampleCount: Int { buckets.reduce(0) { total, bucket in total + bucket.count } }

    var isEmpty: Bool { sampleCount == 0 }

    /// The upper edge of the bucket containing the `fraction` quantile, or
    /// `nil` when nothing was sampled.
    ///
    /// Deliberately not interpolated. MetricKit's bucket widths are chosen by
    /// the system and are not uniform, so interpolating inside one invents
    /// precision the payload does not contain — and this number's job is to
    /// be compared against a budget, where an over-estimate is safe and an
    /// under-estimate is not.
    func upperBound(atQuantile fraction: Double) -> Double? {
        let total = sampleCount
        guard total > 0 else { return nil }
        let target = Double(total) * fraction.clamped(to: Self.quantileRange)
        var seen = 0
        for bucket in buckets {
            seen += bucket.count
            if Double(seen) >= target { return bucket.end }
        }
        return buckets.last?.end
    }

    var medianUpperBound: Double? { upperBound(atQuantile: Self.medianQuantile) }
    var p90UpperBound: Double? { upperBound(atQuantile: Self.p90Quantile) }
    var worstUpperBound: Double? {
        buckets.last { bucket in bucket.count > 0 }?.end
    }
}

// MARK: - Location

/// How the hike's GPS duty divided across Core Location's accuracy classes.
///
/// This is the single most valuable thing MetricKit reports to *this* app.
/// `RecordingEnergyPolicy` decides between `kCLLocationAccuracyBest` and
/// `kCLLocationAccuracyNearestTenMeters` as a function of Low Power Mode and
/// thermal state; `HikeRecorderTests+Energy` proves the decision reaches Core
/// Location. Neither shows that the step-down ever actually *happens* to
/// somebody, because neither runs on a phone that gets hot in a rucksack.
/// ``conservingShare`` is that evidence, and a value of zero across many real
/// walks is a finding rather than a pass.
nonisolated struct LocationAccuracyBreakdown: Codable, Sendable, Equatable {
    var bestSeconds: Double
    var bestForNavigationSeconds: Double
    var nearestTenMetersSeconds: Double
    var hundredMetersSeconds: Double
    var kilometerSeconds: Double
    var threeKilometersSeconds: Double

    init(
        bestSeconds: Double = 0,
        bestForNavigationSeconds: Double = 0,
        nearestTenMetersSeconds: Double = 0,
        hundredMetersSeconds: Double = 0,
        kilometerSeconds: Double = 0,
        threeKilometersSeconds: Double = 0
    ) {
        self.bestSeconds = bestSeconds
        self.bestForNavigationSeconds = bestForNavigationSeconds
        self.nearestTenMetersSeconds = nearestTenMetersSeconds
        self.hundredMetersSeconds = hundredMetersSeconds
        self.kilometerSeconds = kilometerSeconds
        self.threeKilometersSeconds = threeKilometersSeconds
    }

    var totalSeconds: Double {
        bestSeconds + bestForNavigationSeconds + nearestTenMetersSeconds
            + hundredMetersSeconds + kilometerSeconds + threeKilometersSeconds
    }

    /// Time spent at an accuracy the app would only have asked for while
    /// conserving. `nil` when the GPS was not used at all in the period.
    ///
    /// Anything coarser than ten metres is included even though the policy
    /// never selects it: the system may downgrade an app's request on its own
    /// under duress, and duty spent there is still duty the walker paid for.
    var conservingShare: Double? {
        let total = totalSeconds
        guard total > 0 else { return nil }
        let conserving = nearestTenMetersSeconds + hundredMetersSeconds
            + kilometerSeconds + threeKilometersSeconds
        return conserving / total
    }
}

// MARK: - Exits

/// Why the process went away.
///
/// `PERFORMANCE.md` spends a whole section establishing that the alarming
/// footprint peak was the automation rather than the app, and closed on the
/// worry it could not settle: a backgrounded recording that grows toward that
/// figure is a jetsam candidate, and a recording that gets killed loses the
/// hike.
/// ``backgroundMemoryLimitExits`` and ``backgroundMemoryPressureExits`` settle
/// it with the only evidence that counts — how often it happened to a real
/// walker mid-hike.
nonisolated struct ExitBreakdown: Codable, Sendable, Equatable {
    var backgroundMemoryLimitExits: Int
    var backgroundMemoryPressureExits: Int
    var backgroundCPULimitExits: Int
    var backgroundWatchdogExits: Int
    var backgroundTaskTimeoutExits: Int
    /// Terminated while suspended holding a file or sqlite lock. Called out
    /// separately because the app suspends mid-hike with a SwiftData store and
    /// a recording journal open, which is exactly the shape this counts.
    var backgroundLockedFileExits: Int
    var backgroundNormalExits: Int
    var foregroundWatchdogExits: Int
    var foregroundMemoryLimitExits: Int
    var foregroundNormalExits: Int

    init(
        backgroundMemoryLimitExits: Int = 0,
        backgroundMemoryPressureExits: Int = 0,
        backgroundCPULimitExits: Int = 0,
        backgroundWatchdogExits: Int = 0,
        backgroundTaskTimeoutExits: Int = 0,
        backgroundLockedFileExits: Int = 0,
        backgroundNormalExits: Int = 0,
        foregroundWatchdogExits: Int = 0,
        foregroundMemoryLimitExits: Int = 0,
        foregroundNormalExits: Int = 0
    ) {
        self.backgroundMemoryLimitExits = backgroundMemoryLimitExits
        self.backgroundMemoryPressureExits = backgroundMemoryPressureExits
        self.backgroundCPULimitExits = backgroundCPULimitExits
        self.backgroundWatchdogExits = backgroundWatchdogExits
        self.backgroundTaskTimeoutExits = backgroundTaskTimeoutExits
        self.backgroundLockedFileExits = backgroundLockedFileExits
        self.backgroundNormalExits = backgroundNormalExits
        self.foregroundWatchdogExits = foregroundWatchdogExits
        self.foregroundMemoryLimitExits = foregroundMemoryLimitExits
        self.foregroundNormalExits = foregroundNormalExits
    }

    /// Every exit that lost a walker something — a hike being recorded, or a
    /// screen they were looking at. Normal exits are excluded on purpose:
    /// being killed in the app switcher is not a defect.
    var unexpectedTotal: Int {
        backgroundMemoryLimitExits + backgroundMemoryPressureExits
            + backgroundCPULimitExits + backgroundWatchdogExits
            + backgroundTaskTimeoutExits + backgroundLockedFileExits
            + foregroundWatchdogExits + foregroundMemoryLimitExits
    }
}

// MARK: - Signposts

/// One `mxSignpost` span, aggregated over the reporting period.
///
/// The interesting columns are the three the app cannot measure for itself at
/// all: CPU time, average footprint and logical writes *attributed to a named
/// span*. `PerformanceLog` samples CPU process-wide at 1 Hz, which cannot say
/// which feature spent it — the per-scenario CPU table in `PERFORMANCE.md`
/// carries a warning to exactly that effect. See ``FieldSignpost`` for why
/// only a handful of spans are emitted this way.
nonisolated struct SignpostDigest: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var category: String
    var count: Int
    var duration: HistogramSummary?
    var cpuSeconds: Double?
    var averageMemoryBytes: Double?
    var logicalWriteBytes: Double?

    var id: String { "\(category)/\(name)" }

    init(
        name: String,
        category: String,
        count: Int,
        duration: HistogramSummary? = nil,
        cpuSeconds: Double? = nil,
        averageMemoryBytes: Double? = nil,
        logicalWriteBytes: Double? = nil
    ) {
        self.name = name
        self.category = category
        self.count = count
        self.duration = duration
        self.cpuSeconds = cpuSeconds
        self.averageMemoryBytes = averageMemoryBytes
        self.logicalWriteBytes = logicalWriteBytes
    }

    /// CPU seconds per occurrence — the comparable figure across periods, since
    /// a walker who recorded twice as much will burn twice the cumulative CPU
    /// without anything having regressed.
    var cpuSecondsPerOccurrence: Double? {
        guard let cpuSeconds, count > 0 else { return nil }
        return cpuSeconds / Double(count)
    }
}

// MARK: - Digest

/// One MetricKit metric payload, reduced to what this app asks of it.
///
/// Every field maps to an open question in `PERFORMANCE.md` or to a tracked issue.
/// Nothing is collected because MetricKit happens to offer it.
nonisolated struct FieldMetricsDigest: Codable, Sendable, Equatable {
    // Energy — the question the app exists for.
    var foregroundSeconds: Double?
    var backgroundSeconds: Double?
    /// Time the process was alive in the background *because it holds the
    /// location background mode* — i.e. the pocket half of a hike, which is
    /// where the battery is actually spent and where no lab scenario reaches.
    var backgroundLocationSeconds: Double?
    var cpuSeconds: Double?
    var gpuSeconds: Double?
    var locationAccuracy: LocationAccuracyBreakdown?

    // Launch — `PERFORMANCE.md`'s launch finding.
    var timeToFirstDraw: HistogramSummary?
    var optimizedTimeToFirstDraw: HistogramSummary?
    /// The span `FieldSignpost` brackets with `extendLaunchMeasurement`: first
    /// frame *plus* the map's first real render. The launch finding measures
    /// the same span in the Simulator and has no field number for it.
    var extendedLaunch: HistogramSummary?
    var resumeTime: HistogramSummary?

    // Responsiveness — `MainThreadWatchdog`'s field counterpart.
    var applicationHangTime: HistogramSummary?

    // Hitches — the scroll-smoothness item `XCTHitchMetric` cannot supply
    // off-device.
    var hitchTimeRatio: Double?
    var scrollHitchTimeRatio: Double?

    // Radio — the evidence behind `TileNetworkPolicy`'s "one bar in a valley".
    var cellularConditionBars: HistogramSummary?

    // Disk — the tile cache and the photo store, from the outside.
    var logicalWriteBytes: Double?
    var binaryFileBytes: Double?
    /// Everything the app wrote that is not a cache — for this app, overwhelmingly
    /// the durable tile store and the photo files. `SettingsView` measures the
    /// same bytes by enumerating them; this is the system's own answer, taken
    /// without walking a directory on somebody's phone.
    var dataFileBytes: Double?
    var cacheFolderBytes: Double?
    var totalDiskUsedBytes: Double?

    // Memory and reliability.
    var averageSuspendedMemoryBytes: Double?
    var peakMemoryBytes: Double?
    var exits: ExitBreakdown?

    // Per-span attribution.
    var signposts: [SignpostDigest]

    init(
        foregroundSeconds: Double? = nil,
        backgroundSeconds: Double? = nil,
        backgroundLocationSeconds: Double? = nil,
        cpuSeconds: Double? = nil,
        gpuSeconds: Double? = nil,
        locationAccuracy: LocationAccuracyBreakdown? = nil,
        timeToFirstDraw: HistogramSummary? = nil,
        optimizedTimeToFirstDraw: HistogramSummary? = nil,
        extendedLaunch: HistogramSummary? = nil,
        resumeTime: HistogramSummary? = nil,
        applicationHangTime: HistogramSummary? = nil,
        hitchTimeRatio: Double? = nil,
        scrollHitchTimeRatio: Double? = nil,
        cellularConditionBars: HistogramSummary? = nil,
        logicalWriteBytes: Double? = nil,
        binaryFileBytes: Double? = nil,
        dataFileBytes: Double? = nil,
        cacheFolderBytes: Double? = nil,
        totalDiskUsedBytes: Double? = nil,
        averageSuspendedMemoryBytes: Double? = nil,
        peakMemoryBytes: Double? = nil,
        exits: ExitBreakdown? = nil,
        signposts: [SignpostDigest] = []
    ) {
        self.foregroundSeconds = foregroundSeconds
        self.backgroundSeconds = backgroundSeconds
        self.backgroundLocationSeconds = backgroundLocationSeconds
        self.cpuSeconds = cpuSeconds
        self.gpuSeconds = gpuSeconds
        self.locationAccuracy = locationAccuracy
        self.timeToFirstDraw = timeToFirstDraw
        self.optimizedTimeToFirstDraw = optimizedTimeToFirstDraw
        self.extendedLaunch = extendedLaunch
        self.resumeTime = resumeTime
        self.applicationHangTime = applicationHangTime
        self.hitchTimeRatio = hitchTimeRatio
        self.scrollHitchTimeRatio = scrollHitchTimeRatio
        self.cellularConditionBars = cellularConditionBars
        self.logicalWriteBytes = logicalWriteBytes
        self.binaryFileBytes = binaryFileBytes
        self.dataFileBytes = dataFileBytes
        self.cacheFolderBytes = cacheFolderBytes
        self.totalDiskUsedBytes = totalDiskUsedBytes
        self.averageSuspendedMemoryBytes = averageSuspendedMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.exits = exits
        self.signposts = signposts
    }

    /// CPU seconds per hour of the app being alive at all — the only figure in
    /// here that is comparable between a walker who hiked for six hours and
    /// one who checked the map twice.
    var cpuSecondsPerActiveHour: Double? {
        guard let cpuSeconds else { return nil }
        let alive = (foregroundSeconds ?? 0) + (backgroundSeconds ?? 0)
        guard alive > 0 else { return nil }
        return cpuSeconds / (alive / 3600)
    }

    /// The share of the app's lifetime spent in a pocket with the GPS on.
    /// `PERFORMANCE.md` asserts the backgrounded per-fix cost is the one that
    /// decides whether the battery lasts "since that is how the app is used
    /// for all but a few minutes of a walk" — this is that claim, measured.
    ///
    /// Clamped to 1.0, and the clamp is load-bearing rather than cosmetic.
    /// MetricKit accounts `cumulativeBackgroundLocationTime` on a different
    /// clock from `cumulativeForegroundTime`/`cumulativeBackgroundTime` — a
    /// location session that spans a suspension is charged in full to the
    /// former while the latter advance only while the process is resident — so
    /// the ratio is genuinely representable above one. Reporting "112%" reads
    /// as a bug in the app rather than as the accounting difference it is, and
    /// it is not a number the reader can act on either way. The row's footnote
    /// in `FieldMetricsSection` carries the caveat, so the fact is stated once
    /// where someone would look for it rather than encoded in an out-of-range
    /// value nobody can interpret.
    var backgroundLocationShare: Double? {
        guard let backgroundLocationSeconds else { return nil }
        let alive = (foregroundSeconds ?? 0) + (backgroundSeconds ?? 0)
        guard alive > 0 else { return nil }
        return min(1, backgroundLocationSeconds / alive)
    }
}

// MARK: - Diagnostics

/// One entry from a MetricKit *diagnostic* payload — a hang, a crash, a
/// launch that took too long, a disk-write or CPU exception.
///
/// Kept as a flat summary plus the call-stack JSON rather than as a decoded
/// tree: the tree is only ever read by a human looking at a symbolicated
/// stack, and re-modelling `MXCallStackTree` here would be a lot of surface
/// for no question anyone is asking of it in-app.
nonisolated struct FieldDiagnosticDigest: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case appLaunch = "appLaunch"
        case cpuException = "cpuException"
        case crash = "crash"
        case diskWriteException = "diskWriteException"
        case hang = "hang"

        var title: String {
            switch self {
            case .appLaunch: "Slow launch"
            case .cpuException: "Excessive CPU"
            case .crash: "Crash"
            case .diskWriteException: "Excessive disk writes"
            case .hang: "Hang"
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// Duration in seconds for a hang or a slow launch; `nil` for the others.
    var seconds: Double?
    /// Bytes for a disk-write exception; `nil` for the others.
    var bytes: Double?
    /// A crash's termination reason or exception name, when there is one.
    var reason: String?
    var appVersion: String?
    var callStackJSON: Data?

    init(
        kind: Kind,
        id: UUID = UUID(),
        seconds: Double? = nil,
        bytes: Double? = nil,
        reason: String? = nil,
        appVersion: String? = nil,
        callStackJSON: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.seconds = seconds
        self.bytes = bytes
        self.reason = reason
        self.appVersion = appVersion
        self.callStackJSON = callStackJSON
    }
}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
