//
//  TrailMatcherModels.swift
//  OpenHikes
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
    /// The geometry this leg drew by default — the same points as the
    /// corresponding ``TrailMatchLeg/defaultPoints``, not the raw fixes.
    let defaultPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
}

/// What a leg of the saved route is made of.
///
/// `matched` is the geometry the matcher produced — snapped to the trail graph
/// where it was confident, an anchored straight line where it abstained.
/// `gps` is the pair of fixes as they were recorded — a measurement rather
/// than an inference — for every leg that has them. A leg whose `rawPoints`
/// are empty has nothing to give back, and ``TrailMatchLeg/points(for:)``
/// answers with `defaultPoints` instead, since dropping the leg would open a
/// hole in the route.
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
    /// Whether the ground this leg spans went unobserved, so every choice
    /// offered for it is an inference rather than a measurement.
    let isInferred: Bool
    /// How long the recording went without a fix across this leg. `nil` unless
    /// ``isInferred``.
    let unobservedDuration: TimeInterval?
    /// Whether the matcher actually found a mapped route across the leg. A
    /// leg that is `isInferred` but not bridged is the silent case worth
    /// surfacing: a straight line drawn through a stretch nothing is known
    /// about.
    let isBridged: Bool

    init(
        index: Int,
        defaultPoints: [RecordingPoint],
        rawPoints: [RecordingPoint],
        alternatives: [TrailMatchAlternative],
        trailNames: [String],
        isInferred: Bool = false,
        unobservedDuration: TimeInterval? = nil,
        isBridged: Bool = false
    ) {
        self.index = index
        self.defaultPoints = defaultPoints
        self.rawPoints = rawPoints
        self.alternatives = alternatives
        self.trailNames = trailNames
        self.isInferred = isInferred
        self.unobservedDuration = unobservedDuration
        self.isBridged = isBridged
    }
}

nonisolated struct TrailMatchResult: Sendable {
    static let mergeThresholdMeters = 0.05

    let points: [RecordingPoint]
    let matchedLegCount: Int
    /// How many legs the walker will actually be asked about — derived from
    /// ``ambiguities`` rather than counted alongside it, so the two cannot
    /// disagree. They once could: a dense leg the matcher was unsure about
    /// went uncounted *and* unsurfaced, which read as a clean match.
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
        guard !legs.isEmpty else { return points }
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
        case .matched: return defaultPoints
        case .gps: return rawPoints.isEmpty ? defaultPoints : rawPoints
        case .alternative(let alternativeID): return alternatives.first { alternative in
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
