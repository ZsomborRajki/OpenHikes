//
//  RecordingPreparation.swift
//  OpenTrails
//

import Foundation
import OpenTrailsShared

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

    static func normalizedPoints(
        _ points: [RecordingPoint]
    ) -> [RecordingPoint] {
        let ordered = points.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            let firstIsWidget = lhs.flags.contains(.widgetSourced)
            let secondIsWidget = rhs.flags.contains(.widgetSourced)
            if firstIsWidget != secondIsWidget {
                return !firstIsWidget
            }
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
            guard point.timestamp != deduplicated.last?.timestamp else {
                continue
            }
            deduplicated.append(point)
        }
        return deduplicated
    }

    private static func matchedDistance(
        _ points: [RecordingPoint]
    ) -> Double {
        guard points.count > 1 else {
            return 0
        }
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
        guard route.count == raw.count else {
            return true
        }
        return zip(route, raw).contains { routePoint, rawPoint in
            RouteGeometry.distanceMeters(
                from: routePoint.coordinate,
                to: rawPoint.coordinate
            ) > RouteReviewSection.movedThresholdMeters
        }
    }
}
