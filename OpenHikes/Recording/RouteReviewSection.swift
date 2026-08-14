//
//  RouteReviewSection.swift
//  OpenHikes
//
//  Turns the matcher's per-fix legs into the handful of sections a hiker can
//  actually review. A leg spans two consecutive fixes, so a walked hour is
//  thousands of them; what a person can answer for is "this stretch, where
//  matching moved my line — trail or GPS?".
//

import Foundation
import OpenHikesShared

nonisolated struct RouteReviewSection: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Matching moved the line and is confident about where it went.
        case snapped
        /// More than one plausible route fits the gap.
        case ambiguous
    }

    /// How far the matched line has to sit from the recorded fix before the
    /// leg counts as moved. Shared with ``RecordingPreparation`` so "moved"
    /// means one thing across preparation and review.
    static let movedThresholdMeters = 1.0

    /// A run stays open across short stretches the matcher left alone, so a
    /// single agreeing leg doesn't split one decision into two.
    static let absorbedUnmovedDistanceMeters = 100.0

    let id: Int
    let kind: Kind
    let legIndices: [Int]
    /// The matcher's geometry for the whole run.
    let matchedPoints: [RecordingPoint]
    /// The recorded fixes for the whole run.
    let rawPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
    let trailNames: [String]

    /// What the section is saved as until the hiker says otherwise: an
    /// ambiguous stretch keeps the measurement, a confident one keeps the
    /// trail the matcher found.
    var defaultChoice: TrailRouteChoice {
        kind == .ambiguous ? .gps : .matched
    }

    var trailName: String? {
        trailNames.min()
    }

    var matchedDistanceMeters: Double {
        Self.distance(of: matchedPoints)
    }

    var rawDistanceMeters: Double {
        Self.distance(of: rawPoints)
    }

    func points(for choice: TrailRouteChoice) -> [RecordingPoint] {
        switch choice {
        case .matched:
            matchedPoints

        case .gps:
            rawPoints

        case .alternative(let alternativeID):
            alternatives.first { alternative in
                alternative.id == alternativeID
            }?.points ?? matchedPoints
        }
    }

    /// Every choice this section can offer, in the order the review shows them.
    var availableChoices: [TrailRouteChoice] {
        switch kind {
        case .snapped:
            [.matched, .gps]

        case .ambiguous:
            [.gps] + alternatives.map { .alternative($0.id) }
        }
    }

    private static func distance(of points: [RecordingPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + RouteGeometry.distanceMeters(
                from: pair.0.coordinate,
                to: pair.1.coordinate
            )
        }
    }
}

// MARK: - Building

nonisolated extension RouteReviewSection {
    /// Groups without occupying the main actor.
    ///
    /// `@concurrent` rather than a detached task: grouping walks every leg, so
    /// it stays off the UI, but it stays in the save task — abandoning the save
    /// abandons this too, and it runs at the save's own priority.
    @concurrent
    static func sectionsOffMain(in result: TrailMatchResult) async -> [Self] {
        assertOffMainThread(
            "Route review grouping must stay off the main thread"
        )
        return sections(in: result)
    }

    /// Groups the legs matching actually changed into reviewable sections.
    /// Legs the matcher left on the recorded line offer no choice, so they
    /// never become a section of their own.
    static func sections(in result: TrailMatchResult) -> [Self] {
        var sections: [Self] = []
        var run = Run()

        func flush() {
            if let section = run.section(id: sections.count) {
                sections.append(section)
            }
            run = Run()
        }

        for leg in result.legs {
            if !leg.alternatives.isEmpty {
                flush()
                sections.append(
                    Self(
                        id: sections.count,
                        kind: .ambiguous,
                        legIndices: [leg.index],
                        matchedPoints: leg.defaultPoints,
                        rawPoints: leg.rawPoints,
                        alternatives: leg.alternatives,
                        trailNames: leg.trailNames
                    )
                )
                continue
            }
            if legMoved(leg) {
                run.append(leg, moved: true)
            } else if run.isOpen,
                      run.unmovedDistanceMeters
                      + legDistance(leg) <= absorbedUnmovedDistanceMeters {
                run.append(leg, moved: false)
            } else {
                flush()
            }
        }
        flush()
        return sections
    }

    static func legMoved(_ leg: TrailMatchLeg) -> Bool {
        guard !leg.rawPoints.isEmpty else { return false }
        guard leg.defaultPoints.count == leg.rawPoints.count else { return true }
        return zip(leg.defaultPoints, leg.rawPoints).contains { matched, raw in
            RouteGeometry.distanceMeters(
                from: matched.coordinate,
                to: raw.coordinate
            ) > movedThresholdMeters
        }
    }

    private static func legDistance(_ leg: TrailMatchLeg) -> Double {
        distance(of: leg.rawPoints)
    }

    /// Accumulates consecutive legs until something ends the run: an ambiguous
    /// leg, or a stretch the matcher agreed with that is long enough to be a
    /// separate part of the walk.
    private struct Run {
        private(set) var legIndices: [Int] = []
        private(set) var matchedPoints: [RecordingPoint] = []
        private(set) var rawPoints: [RecordingPoint] = []
        private(set) var trailNames: Set<String> = []
        private(set) var unmovedDistanceMeters = 0.0
        private var containsMovedLeg = false

        var isOpen: Bool {
            !legIndices.isEmpty
        }

        mutating func append(_ leg: TrailMatchLeg, moved: Bool) {
            legIndices.append(leg.index)
            matchedPoints.appendJoiningRoute(leg.defaultPoints)
            rawPoints.appendJoiningRoute(leg.rawPoints)
            trailNames.formUnion(leg.trailNames)
            if moved {
                containsMovedLeg = true
                unmovedDistanceMeters = 0
            } else {
                unmovedDistanceMeters += RouteReviewSection.legDistance(leg)
            }
        }

        func section(id: Int) -> RouteReviewSection? {
            guard containsMovedLeg else { return nil }
            return RouteReviewSection(
                id: id,
                kind: .snapped,
                legIndices: legIndices,
                matchedPoints: matchedPoints,
                rawPoints: rawPoints,
                alternatives: [],
                trailNames: trailNames.sorted()
            )
        }
    }
}
