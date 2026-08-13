//
//  TrailMatcherModels.swift
//  OpenTrails
//

import Foundation

nonisolated struct TrailMatchAlternative: Equatable, Sendable {
    let id: Int
    let points: [RecordingPoint]
    let distanceMeters: Double
    let trailNames: [String]
}

nonisolated struct TrailMatchAmbiguity: Equatable, Identifiable, Sendable {
    let id: Int
    let gpsPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
}

/// What a leg of the saved route is made of.
///
/// `matched` is the geometry the matcher produced — snapped to the trail graph
/// where it was confident, an anchored straight line where it abstained.
/// `gps` is the pair of fixes as they were recorded, so choosing it always
/// gives back a measurement rather than an inference.
nonisolated enum TrailRouteChoice: Equatable, Sendable {
    case alternative(Int)
    case gps
    case matched
}

nonisolated struct TrailMatchLeg: Sendable {
    let index: Int
    let defaultPoints: [RecordingPoint]
    /// The two recorded fixes this leg spans, kept so the hiker can hand the
    /// leg back to its GPS geometry during review.
    let rawPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
    /// Names of the trails the matched geometry runs along, empty when the
    /// matcher abstained.
    let trailNames: [String]
}

nonisolated struct TrailMatchResult: Sendable {
    static let mergeThresholdMeters = 0.05

    let points: [RecordingPoint]
    let matchedLegCount: Int
    let ambiguousLegCount: Int
    let matchedTrailName: String?
    let currentTrailName: String?
    let didMoveRoute: Bool
    let ambiguities: [TrailMatchAmbiguity]
    let legs: [TrailMatchLeg]

    /// Rebuilds the route from a per-leg choice. A leg with no entry keeps the
    /// matcher's own geometry, so a partial dictionary only moves what the
    /// hiker actually touched.
    func points(
        resolving choices: [Int: TrailRouteChoice]
    ) -> [RecordingPoint] {
        guard !legs.isEmpty else {
            return points
        }
        var output: [RecordingPoint] = []
        for leg in legs {
            output.appendJoiningRoute(leg.points(for: choices[leg.index] ?? .matched))
        }
        return output
    }
}

nonisolated extension TrailMatchLeg {
    func points(for choice: TrailRouteChoice) -> [RecordingPoint] {
        switch choice {
        case .matched:
            return defaultPoints

        case .gps:
            return rawPoints.isEmpty ? defaultPoints : rawPoints

        case .alternative(let alternativeID):
            return alternatives.first { alternative in
                alternative.id == alternativeID
            }?.points ?? defaultPoints
        }
    }
}

nonisolated extension [RecordingPoint] {
    /// Appends a route segment, dropping its first point when it repeats the
    /// point already at the end — the join two adjacent legs share.
    mutating func appendJoiningRoute(_ segment: [RecordingPoint]) {
        guard !isEmpty else {
            append(contentsOf: segment)
            return
        }
        guard let previous = last,
              let first = segment.first,
              RouteGeometry.distanceMeters(
                  from: previous.coordinate,
                  to: first.coordinate
              ) <= TrailMatchResult.mergeThresholdMeters else {
            append(contentsOf: segment)
            return
        }
        append(contentsOf: segment.dropFirst())
    }
}
