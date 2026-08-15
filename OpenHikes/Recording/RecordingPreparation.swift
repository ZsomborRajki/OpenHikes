//
//  RecordingPreparation.swift
//  OpenHikes
//

import Foundation
import OpenHikesShared

nonisolated struct PreparedRecording: Sendable {
    let route: [RouteCoordinate]
    /// The unmatched trace, kept once matching makes `route` differ from it.
    let rawRoute: [RouteCoordinate]
    let distanceMeters: Double
    let startedAt: Date
    let endedAt: Date
    let matchedTrailName: String?
    let ambiguousLegCount: Int
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
        endedAt: Date,
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
            endedAt: endedAt,
            graph: graph,
            gapDistances: gapDistances,
            routeChoices: routeChoices
        )
    }

    /// Turns journalled fixes into the values a `Hike` is built from.
    static func prepare(
        points: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
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
            endedAt: endedAt,
            match: match,
            routeChoices: routeChoices
        )
    }

    /// Resolves review choices without occupying the main actor. `@concurrent`
    /// for the same reasons as ``prepareOffMain(points:startedAt:endedAt:graph:gapDistances:routeChoices:)``.
    @concurrent
    static func prepareResolvedOffMain(
        points: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
        matchResult: TrailMatchResult,
        choices: [Int: TrailRouteChoice]
    ) async throws(RecordingFailure) -> PreparedRecording {
        assertOffMainThread(
            "Route review resolution must stay off the main thread"
        )
        return try prepareResolved(
            points: points,
            startedAt: startedAt,
            endedAt: endedAt,
            matchResult: matchResult,
            choices: choices
        )
    }

    static func prepareResolved(
        points: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
        matchResult: TrailMatchResult,
        choices: [Int: TrailRouteChoice]
    ) throws(RecordingFailure) -> PreparedRecording {
        let deduplicated = normalizedPoints(points)
        guard deduplicated.count > 1 else { throw .tooShort }
        return preparedRecording(
            points: deduplicated,
            startedAt: startedAt,
            endedAt: endedAt,
            match: matchResult,
            routeChoices: choices
        )
    }

    private static func preparedRecording(
        points deduplicated: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
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

        let distanceMeters: Double
        if usesMatchedRoute {
            distanceMeters = matchedDistance(preparedPoints)
        } else {
            var accumulator = RecordingDistanceAccumulator()
            for point in preparedPoints {
                accumulator.append(point)
            }
            distanceMeters = accumulator.distanceMeters
        }
        return PreparedRecording(
            route: preparedPoints.map(\.routeCoordinate),
            // No match means `route` already is the raw trace; a second copy
            // would double the row without preserving any additional fact.
            rawRoute: usesMatchedRoute ? rawRoute : [],
            distanceMeters: distanceMeters,
            startedAt: startedAt,
            endedAt: endedAt,
            matchedTrailName: usesMatchedRoute
                ? match?.matchedTrailName
                : nil,
            ambiguousLegCount: routeChoices.isEmpty
                ? match?.ambiguousLegCount ?? 0
                : 0,
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

    private static func matchedDistance(
        _ points: [RecordingPoint]
    ) -> Double {
        guard points.count > 1 else { return 0 }
        var distance = 0.0
        for index in 1..<points.count {
            guard !points[index].flags.contains(.resumed) else { continue }
            distance += RouteGeometry.distanceMeters(
                from: points[index - 1].coordinate,
                to: points[index].coordinate
            )
        }
        return distance
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
