//
//  RecordingPreparation.swift
//  OpenHikes
//

import CoreLocation
import Foundation
import OpenHikesShared

nonisolated struct PreparedRecording: Sendable {
    let route: [RouteCoordinate]
    /// The unmatched trace, kept once matching makes `route` differ from it.
    let rawRoute: [RouteCoordinate]
    let distanceMeters: Double
    /// The saved line's own length: the plain sum along `route`, with none of
    /// the stationary windows ``distanceMeters`` retracts.
    ///
    /// Not a second opinion about how far the walker went — `distanceMeters`
    /// is that, and is the figure the hike shows. This is the *axis* a walk's
    /// coverage is measured on, which is `RouteProfile.totalDistanceMeters`
    /// and nothing else: `TrailWalkSession` starts every followed walk
    /// against that number, and `WalkSummaryView` compares a walk's stored
    /// route length back against it to decide whether the trail on screen is
    /// still the one that was walked. So the recording's own walk — see
    /// ``HikeWalk/recorded(_:prepared:)`` — has to be written on the same
    /// scale, or it would read as a walk along a trail that has since
    /// changed.
    ///
    /// Summed here, where the points are already being walked off the main
    /// thread, rather than by building a `RouteProfile` at save time: that is
    /// twenty thousand points of trigonometry on the main actor, at the one
    /// moment a walker is waiting for their hike to appear.
    let routeLengthMeters: Double
    /// How long the recording was actually recording: the sum of the gaps
    /// between consecutive saved points, with the leg a pause opened left
    /// out — ``RecordingDistanceAccumulator/recordedDuration``, the same
    /// figure the live average speed is divided by.
    ///
    /// The evidence is the points rather than the clock, because the clock
    /// counts time nothing was recorded. `TrackJournalMetadata.pausedIntervals`
    /// is not the whole record of when a recording was not running:
    /// `HikeRecorder.finishRecovery` parks a session recovered at launch in
    /// `.paused` / `.needsDecision` without writing a pause, and no interval
    /// exists at all for the stretch between the process being killed and the
    /// relaunch that found the journal. A walk measured on wall-clock minus
    /// those intervals reported a walk of one minute, recovered an hour later,
    /// as an hour and eleven minutes of walking.
    ///
    /// A gap the walker *did* walk still counts: a lost signal is an ordinary
    /// gap between two consecutive points and is summed like any other. Only a
    /// pause boundary — see ``RouteBoundary`` — takes its leg out.
    let recordedSeconds: TimeInterval
    let startedAt: Date
    let matchedTrailName: String?
    let matchResult: TrailMatchResult?
}

nonisolated enum RecordingPreparation {
    /// Prepares without occupying the main actor.
    ///
    /// `@concurrent` rather than a detached task: the matching and distance
    /// work stays in the caller's task, so the caller's priority carries
    /// through, and — because the typed `throws(RecordingFailure)` survives —
    /// the failure propagates as itself. A detached task erases it to
    /// `any Error`, which forced the caller to re-catch and re-wrap a value
    /// it had already typed.
    @concurrent
    static func prepareOffMain(
        points: [RecordingPoint],
        startedAt: Date,
        graph: TrailGraph? = nil,
        gapDistances: [Int: Double] = [:],
        routeChoices: [Int: TrailRouteChoice] = [:]
    ) async throws(RecordingFailure) -> PreparedRecording {
        assertOffMainThread(
            "Recording preparation must stay off the main thread"
        )
        return try prepare(
            points: points,
            startedAt: startedAt,
            graph: graph,
            gapDistances: gapDistances,
            routeChoices: routeChoices
        )
    }

    /// Turns journalled fixes into the values a `Hike` is built from.
    static func prepare(
        points: [RecordingPoint],
        startedAt: Date,
        graph: TrailGraph? = nil,
        gapDistances: [Int: Double] = [:],
        routeChoices: [Int: TrailRouteChoice] = [:]
    ) throws(RecordingFailure) -> PreparedRecording {
        let deduplicated = normalizedPoints(points)
        guard deduplicated.count > 1 else { throw .tooShort }

        let match = graph.map { trailGraph in
            TrailMatcher.match(
                points: deduplicated,
                graph: trailGraph,
                gapDistances: gapDistances
            )
        }
        return preparedRecording(
            points: deduplicated,
            startedAt: startedAt,
            match: match,
            routeChoices: routeChoices
        )
    }

    /// Resolves review choices without occupying the main actor. `@concurrent`
    /// for the same reasons as ``prepareOffMain(points:startedAt:graph:gapDistances:routeChoices:)``.
    @concurrent
    static func prepareResolvedOffMain(
        points: [RecordingPoint],
        startedAt: Date,
        matchResult: TrailMatchResult,
        choices: [Int: TrailRouteChoice]
    ) async throws(RecordingFailure) -> PreparedRecording {
        assertOffMainThread(
            "Route review resolution must stay off the main thread"
        )
        return try prepareResolved(
            points: points,
            startedAt: startedAt,
            matchResult: matchResult,
            choices: choices
        )
    }

    static func prepareResolved(
        points: [RecordingPoint],
        startedAt: Date,
        matchResult: TrailMatchResult,
        choices: [Int: TrailRouteChoice]
    ) throws(RecordingFailure) -> PreparedRecording {
        let deduplicated = normalizedPoints(points)
        guard deduplicated.count > 1 else { throw .tooShort }
        return preparedRecording(
            points: deduplicated,
            startedAt: startedAt,
            match: matchResult,
            routeChoices: choices
        )
    }

    private static func preparedRecording(
        points deduplicated: [RecordingPoint],
        startedAt: Date,
        match: TrailMatchResult?,
        routeChoices: [Int: TrailRouteChoice]
    ) -> PreparedRecording {
        let rawRoute = deduplicated.map(\.routeCoordinate)
        let preparedPoints: [RecordingPoint]
        if let match, !routeChoices.isEmpty {
            preparedPoints = match.points(resolving: routeChoices)
        } else {
            preparedPoints = match?.points ?? deduplicated
        }
        let usesMatchedRoute = routeMoved(
            preparedPoints,
            from: deduplicated
        )

        // One distance rule, whether or not matching moved the line: the same
        // accumulator the walker watched tick during the recording, replayed
        // over whatever geometry is being saved. A plain sum over the matched
        // legs is not the same rule — it hands back the stationary windows the
        // live readout retracted — so the hike came out longer than the walk
        // the walker watched, with nothing to say which figure to believe.
        var accumulator = RecordingDistanceAccumulator()
        // The geometric length rides along in the same pass, by the same
        // arithmetic `RouteProfile` uses on the saved row — see
        // ``PreparedRecording/routeLengthMeters``.
        var routeLength = 0.0
        var previousCoordinate: CLLocationCoordinate2D?
        for point in preparedPoints {
            accumulator.append(point)
            if let previousCoordinate {
                routeLength += RouteGeometry.distanceMeters(
                    from: previousCoordinate,
                    to: point.coordinate
                )
            }
            previousCoordinate = point.coordinate
        }
        return PreparedRecording(
            route: preparedPoints.map(\.routeCoordinate),
            // No match means `route` already is the raw trace; a second copy
            // would double the row without preserving any additional fact.
            rawRoute: usesMatchedRoute ? rawRoute : [],
            distanceMeters: accumulator.distanceMeters,
            routeLengthMeters: routeLength,
            recordedSeconds: accumulator.recordedDuration,
            startedAt: startedAt,
            matchedTrailName: usesMatchedRoute
                ? match?.matchedTrailName
                : nil,
            matchResult: match
        )
    }

    /// Normalizes without occupying the main actor.
    ///
    /// `@concurrent` rather than a detached task: the sort and dedup stay in
    /// the caller's task, so abandoning a recovery or a resync cancels them
    /// and the caller's priority carries through instead of being pinned here.
    @concurrent
    static func normalizedPointsOffMain(
        _ points: [RecordingPoint]
    ) async -> [RecordingPoint] {
        assertOffMainThread(
            "Recording normalization must stay off the main thread"
        )
        return normalizedPoints(points)
    }

    static func normalizedPoints(
        _ points: [RecordingPoint]
    ) -> [RecordingPoint] {
        let ordered = points.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            let firstIsWidget = lhs.flags.contains(.widgetSourced)
            let secondIsWidget = rhs.flags.contains(.widgetSourced)
            if firstIsWidget != secondIsWidget { return !firstIsWidget }
            return lhs.horizontalAccuracy < rhs.horizontalAccuracy
        }
        let foregroundTimestamps = TimestampIndex(
            ordered.compactMap { point in
                point.flags.contains(.widgetSourced) ? nil : point.timestamp
            }
        )
        var deduplicated: [RecordingPoint] = []
        deduplicated.reserveCapacity(ordered.count)
        for point in ordered {
            if point.flags.contains(.widgetSourced),
               foregroundTimestamps.contains(point.timestamp, within: 5) {
                continue
            }
            guard point.timestamp != deduplicated.last?.timestamp else { continue }
            deduplicated.append(point)
        }
        return deduplicated
    }

    private static func routeMoved(
        _ route: [RecordingPoint],
        from raw: [RecordingPoint]
    ) -> Bool {
        guard route.count == raw.count else { return true }
        return zip(route, raw).contains { routePoint, rawPoint in
            RouteGeometry.distanceMeters(
                from: routePoint.coordinate,
                to: rawPoint.coordinate
            ) > RouteReviewSection.movedThresholdMeters
        }
    }
}
