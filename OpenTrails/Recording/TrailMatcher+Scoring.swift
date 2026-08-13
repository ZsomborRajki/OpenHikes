//
//  TrailMatcher+Scoring.swift
//  OpenTrails
//

import CoreLocation
import Foundation

nonisolated extension TrailMatcher {
    static func emptyMatchResult(points: [RecordingPoint]) -> TrailMatchResult {
        TrailMatchResult(
            points: points,
            matchedLegCount: 0,
            ambiguousLegCount: 0,
            matchedTrailName: nil,
            currentTrailName: nil,
            didMoveRoute: false,
            ambiguities: [],
            legs: []
        )
    }

    static func updateConfidentLegStats(
        from previous: TrailMatcherCandidate,
        to current: TrailMatcherCandidate,
        transition: TrailMatcherTransition,
        trailNameCounts: inout [String: Int],
        didMoveRoute: inout Bool
    ) {
        if previous.offRouteMeters > 1
            || current.offRouteMeters > 1
            || transition.coordinates.count > 2 {
            didMoveRoute = true
        }
        for name in transition.trailNames {
            trailNameCounts[name, default: 0] += 1
        }
    }

    static func transitionParameters(
        from previous: RecordingPoint,
        to current: RecordingPoint,
        evidenceDistance: Double?
    ) -> TrailMatcherTransitionParameters {
        let interval = max(
            1,
            current.timestamp.timeIntervalSince(previous.timestamp)
        )
        let direct = RouteGeometry.distanceMeters(
            from: previous.coordinate,
            to: current.coordinate
        )
        let sparse = interval > sparseInterval || direct > sparseDisplacement
        let expected = max(0, evidenceDistance ?? direct)
        let maximumSpeed = sparse ? sparseMaximumSpeedMPS : denseMaximumSpeedMPS
        let accuracyAllowance =
            previous.horizontalAccuracy + current.horizontalAccuracy
        let evidenceBound = evidenceDistance.map { dist in
            dist * evidenceDistanceMarginFactor + accuracyAllowance
        } ?? 0
        let maximumDistance = max(
            minimumTransitionDistanceMeters,
            max(
                interval * maximumSpeed + accuracyAllowance,
                evidenceBound
            )
        )
        return TrailMatcherTransitionParameters(
            expectedDistance: expected,
            maximumDistance: maximumDistance,
            beta: max(10, min(180, interval * 0.5)),
            isSparse: sparse,
            hasDistanceEvidence: evidenceDistance != nil,
            startEndpointTolerance: max(
                minimumSigmaMeters,
                previous.horizontalAccuracy
            ),
            endEndpointTolerance: max(
                minimumSigmaMeters,
                current.horizontalAccuracy
            )
        )
    }

    static func emissionLogProbability(
        _ candidate: TrailMatcherCandidate,
        for point: RecordingPoint
    ) -> Double {
        let sourceWeight = point.flags.contains(.widgetSourced)
            ? widgetSourcedAccuracyWeight
            : 1.0
        let sigma = max(
            minimumSigmaMeters,
            point.horizontalAccuracy * sourceWeight
        )
        return -(candidate.offRouteMeters * candidate.offRouteMeters)
            / (2 * sigma * sigma)
    }

    static func transitionLogProbability(
        _ routeDistance: Double,
        parameters: TrailMatcherTransitionParameters
    ) -> Double {
        -abs(routeDistance - parameters.expectedDistance) / parameters.beta
    }

    static func bestIndex(in scores: [Double]) -> Int? {
        scores.indices
            .filter { index in scores[index].isFinite }
            .max { lhs, rhs in scores[lhs] < scores[rhs] }
    }

    static func margin(
        for selectedIndex: Int,
        in scores: [Double],
        candidates: [TrailMatcherCandidate]
    ) -> Double {
        let selected = scores[selectedIndex]
        let selectedCoordinate = candidates[selectedIndex].projectedCoordinate
        let runnerUp = scores.indices
            .filter { index in
                index != selectedIndex
                    && scores[index].isFinite
                    && RouteGeometry.distanceMeters(
                        from: candidates[index].projectedCoordinate,
                        to: selectedCoordinate
                    ) > 1
            }
            .map { index in scores[index] }
            .max()
        return runnerUp.map { best in selected - best } ?? .infinity
    }

    static func point(
        _ source: RecordingPoint,
        movedTo coordinate: CLLocationCoordinate2D
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timestamp: source.timestamp,
            horizontalAccuracy: source.horizontalAccuracy,
            elevation: source.elevation,
            course: source.course,
            speed: source.speed,
            flags: source.flags
        )
    }
}
