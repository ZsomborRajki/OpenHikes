//
//  FieldSignpost.swift
//  OpenHikes
//
//  Four spans, chosen carefully, that MetricKit aggregates from real walks.
//
//  `RenderSignpost` already brackets around forty things, and re-emitting all
//  of them through MetricKit would be both wrong and useless. Apple is
//  explicit about why: "To limit on-device overhead, the system will
//  automatically limit the number of signposts (emitted using the MetricKit
//  log handle) processed. Avoid losing telemetry by limiting usage of
//  signposts to critical sections of code." A budget spent on `TrailMatcherWork`
//  — which fires once per accepted fix, roughly two thousand times a hike —
//  buys a histogram of a 0.02 ms function and throws away the four spans that
//  actually answer a question.
//
//  So the selection is by *question*, not by cost, and every span here is
//  coarse, infrequent, and bounded by a user action:
//
//  | Span | The question it answers |
//  |---|---|
//  | `RecordingSession` | "Measure a real hike-length recording's energy" — `PERFORMANCE.md`, "Blind spots" |
//  | `OfflineDownload` | "Auto-save and a maximum-budget offline download" — `PERFORMANCE.md`, "Validating on a device" |
//  | `HikeImport` | GPX parse, statistics and first render, end to end |
//  | `TrailGraphPrefetch` | What reaching Overpass mid-hike costs, radio included |
//
//  `RecordingSession` is the important one and is the reason this file exists.
//  What comes back for it is not a duration — the app already knows how long a
//  recording lasted — but `MXSignpostIntervalData`'s other three columns:
//  cumulative CPU time, average footprint, and cumulative logical writes,
//  *attributed to the recording* rather than to the process. `PerformanceLog`
//  samples all three process-wide at 1 Hz and cannot attribute any of them,
//  which is why `PERFORMANCE.md`'s per-scenario CPU table carries a warning
//  that it "says more about how much a scenario queries the accessibility tree
//  than about the feature it names". This is that table, without the warning,
//  from a phone in somebody's pocket.
//
//  Two caveats it is cheaper to know than to rediscover:
//
//  * A span that is still open when MetricKit closes its 24-hour period is not
//    reported. Every span here is comfortably shorter than a day, but a
//    recording left running overnight will simply not appear.
//  * On the Simulator `mxSignpost` still compiles and still emits an
//    `os_signpost` — visible in Instruments — but carries "NO_METRICS" instead
//    of a metrics snapshot. Nothing here can be verified anywhere but on a
//    device.
//
//  Unlike the rest of `Diagnostics/`, this is *not* `#if DEBUG`: a signpost
//  compiled out of the shipping build produces no field telemetry, which is
//  the only kind MetricKit has.
//

import Foundation
import MetricKit
import os

nonisolated enum FieldSignpost {
    /// The spans worth paying MetricKit's telemetry budget for. Adding one is
    /// a deliberate act: read the note at the top of this file first.
    enum Span: String, CaseIterable, Sendable {
        case hikeImport = "HikeImport"
        case offlineDownload = "OfflineDownload"
        case recordingSession = "RecordingSession"
        case trailGraphPrefetch = "TrailGraphPrefetch"

        /// `mxSignpost` needs a `StaticString`, and a `RawRepresentable`'s
        /// `rawValue` is a `String`. Spelling both is the price of having the
        /// cases enumerable, which is what lets a test assert that the set has
        /// not quietly grown.
        var signpostName: StaticString {
            switch self {
            case .hikeImport: "HikeImport"
            case .offlineDownload: "OfflineDownload"
            case .recordingSession: "RecordingSession"
            case .trailGraphPrefetch: "TrailGraphPrefetch"
            }
        }
    }

    /// An open span. Carries its own `OSSignpostID` rather than using
    /// `.exclusive`, so two overlapping spans — a tile download started while
    /// a recording is running, which is an ordinary thing to do — do not close
    /// each other's intervals.
    ///
    /// The two stored properties are internal rather than private only because
    /// `FieldSignpost` itself has to read them; nothing outside this file
    /// constructs a `Token`, since there is no public initializer.
    struct Token: Sendable {
        let span: Span
        let id: OSSignpostID
    }

    /// The MetricKit-flagged log handle. A signpost emitted on any other log
    /// is invisible to MetricKit, however well named.
    ///
    /// The category becomes `MXSignpostMetric.signpostCategory`, so it is what
    /// distinguishes these four from anything else the app might aggregate
    /// later.
    static let category = "Hiking"
    static let log: OSLog = MXMetricManager.makeLogHandle(category: category)

    static func begin(_ span: Span) -> Token {
        let token = Token(span: span, id: OSSignpostID(log: log))
        mxSignpost(.begin, log: log, name: span.signpostName, signpostID: token.id)
        return token
    }

    static func end(_ token: Token) {
        mxSignpost(.end, log: log, name: token.span.signpostName, signpostID: token.id)
    }
}

// MARK: - Extended launch

extension MXLaunchTaskID {
    /// The span `PERFORMANCE.md`'s launch finding measures: from
    /// `didFinishLaunchingWithOptions` to the moment SwiftUI asks the map
    /// representable to build its `MKMapView`. Opening the SwiftData store,
    /// building the model and evaluating the view tree down to the map all sit
    /// inside it — the app's own share of the time a walker spends looking at
    /// a screen with no map on it.
    ///
    /// It ends *before* `MKMapView()` runs:
    /// ``LaunchMeasurement/finish()`` is the first statement of
    /// `MapView.makeMapView(_:)`, above the constructor. The boundary is the
    /// hand-off to MapKit, not MapKit being ready, so map construction and the
    /// sheet's first few renders are outside the metric by design — they are
    /// not this app's work to shorten, and folding them in would make the
    /// histogram move with a framework version.
    ///
    /// `histogrammedTimeToFirstDraw` stops earlier still, at the first CA
    /// commit, which on this app is a sheet over an empty map; on its own it
    /// would report the app as launching faster than it becomes usable.
    /// Extending the launch past it is what makes `histogrammedExtendedLaunch`
    /// measure something a change to this app can move.
    ///
    /// The `FirstMapFrame` identifier is kept as it is: it is the key field
    /// reports are already keyed by, and renaming it would split the histogram
    /// across app versions.
    static let firstMapFrame = MXLaunchTaskID("FirstMapFrame")
}

/// Brackets the launch task above.
///
/// Separate from ``FieldSignpost`` because the mechanism is different in a way
/// that matters: `extendLaunchMeasurement` must be called on the main thread,
/// must begin before the first scene becomes active, and — unlike a signpost —
/// leaves the launch measurement permanently open if it is never finished.
/// That last one is why ``finish()`` is idempotent and called from two places.
@MainActor
enum LaunchMeasurement {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "FieldMetrics"
    )
    private static var state: State = .notStarted

    private enum State {
        case finished
        case measuring
        case notStarted
    }

    /// Call from the app's `init()`, which runs at
    /// `application(_:didFinishLaunchingWithOptions:)` time — inside the
    /// window the API requires and before any scene connects.
    static func begin() {
        guard case .notStarted = state else { return }
        do {
            try MXMetricManager.extendLaunchMeasurement(forTaskID: .firstMapFrame)
            state = .measuring
        } catch {
            // Not a failure worth surfacing: the app launches the same either
            // way, and the only loss is one histogram in a report that is a
            // day away. Logged so a missing `extendedLaunch` column has an
            // explanation on the device that produced it.
            logger.debug(
                "Extended launch measurement unavailable: \(error.localizedDescription, privacy: .public)"
            )
            state = .finished
        }
    }

    /// Call when the app has finished its own launch work and is about to
    /// hand off to MapKit — in practice the first statement of
    /// `MapView.makeMapView(_:)`, above `MKMapView()` itself.
    ///
    /// Idempotent, and safe to call from a path that may never have begun: a
    /// launch that failed to open its SwiftData store never builds a map, and
    /// an unfinished measurement would sit open for the life of the process.
    static func finish() {
        guard case .measuring = state else { return }
        state = .finished
        do {
            try MXMetricManager.finishExtendedLaunchMeasurement(forTaskID: .firstMapFrame)
        } catch {
            logger.debug(
                "Extended launch measurement did not finish: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
