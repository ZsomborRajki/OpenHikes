//
//  RouteMovedPredicateTests.swift
//  OpenHikesTests
//
//  `RouteReviewSection.pointsMoved(_:from:)` is the one rule for whether a
//  line moved off its recorded fixes. Preparation reads it to keep a raw
//  trace, review reads it to pick the legs a hiker answers for; these pin the
//  rule itself, the review's own empty-leg guard on top of it, and that the
//  save and review answer alike for the same leg.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Route moved predicate")
struct RouteMovedPredicateTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)
    /// Meters per degree of latitude, near enough for offsets of a meter or two.
    private let metersPerDegree = 111_195.0

    private func point(
        _ latitude: Double,
        _ longitude: Double,
        at offset: TimeInterval
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: longitude,
            timestamp: start.addingTimeInterval(offset),
            horizontalAccuracy: 8
        )
    }

    private var raw: [RecordingPoint] {
        [
            point(47.5000, 19.0400, at: 0),
            point(47.5010, 19.0400, at: 60),
            point(47.5020, 19.0400, at: 120),
        ]
    }

    /// The raw fixes with the middle one pushed north by `meters`.
    private func displaced(by meters: Double) -> [RecordingPoint] {
        var points = raw
        let middle = points[1]
        points[1] = point(
            middle.latitude + meters / metersPerDegree,
            middle.longitude,
            at: 60
        )
        let actual = RouteGeometry.distanceMeters(
            from: middle.coordinate,
            to: points[1].coordinate
        )
        #expect(
            actual.isApproximatelyEqual(to: meters, absoluteTolerance: 0.05),
            "fixture offset is \(actual) m"
        )
        return points
    }

    @Test("identical points have not moved")
    func identicalPointsHaveNotMoved() {
        #expect(!RouteReviewSection.pointsMoved(raw, from: raw))
    }

    @Test("two empty lines have not moved")
    func emptyLinesHaveNotMoved() {
        #expect(!RouteReviewSection.pointsMoved([], from: []))
    }

    @Test("a different point count is a move, even along the same line")
    func differentCountIsAMove() {
        #expect(RouteReviewSection.pointsMoved(Array(raw.prefix(2)), from: raw))
        #expect(RouteReviewSection.pointsMoved(raw, from: Array(raw.prefix(2))))
        #expect(RouteReviewSection.pointsMoved(raw, from: []))
    }

    @Test("a displacement under the threshold is not a move")
    func displacementUnderThresholdIsNotAMove() {
        let nudged = displaced(by: RouteReviewSection.movedThresholdMeters / 2)
        #expect(!RouteReviewSection.pointsMoved(nudged, from: raw))
    }

    @Test("a displacement past the threshold is a move")
    func displacementPastThresholdIsAMove() {
        let moved = displaced(by: RouteReviewSection.movedThresholdMeters * 2)
        #expect(RouteReviewSection.pointsMoved(moved, from: raw))
    }

    @Test("a leg follows the shared rule")
    func legFollowsTheSharedRule() {
        let still = TrailMatchLeg(
            index: 0,
            defaultPoints: raw,
            rawPoints: raw,
            alternatives: [],
            trailNames: []
        )
        let moved = TrailMatchLeg(
            index: 1,
            defaultPoints: displaced(by: RouteReviewSection.movedThresholdMeters * 2),
            rawPoints: raw,
            alternatives: [],
            trailNames: []
        )
        #expect(!RouteReviewSection.legMoved(still))
        #expect(RouteReviewSection.legMoved(moved))
    }

    @Test("a leg with no recorded fixes is never reviewed as moved")
    func legWithoutRawFixesIsNotMoved() {
        let leg = TrailMatchLeg(
            index: 0,
            defaultPoints: raw,
            rawPoints: [],
            alternatives: [],
            trailNames: []
        )
        // The shared rule calls this a move; the review's guard overrules it.
        #expect(RouteReviewSection.pointsMoved(leg.defaultPoints, from: leg.rawPoints))
        #expect(!RouteReviewSection.legMoved(leg))
    }

    /// The reason there is one rule: the save keeps the raw trace beside the
    /// matched line exactly when review calls the same geometry moved. The
    /// tests above pin the rule; this pins that preparation still reads it,
    /// so a copy with its own threshold or count check fails here.
    @Test("a save keeps the raw trace exactly when review calls the leg moved")
    func saveAgreesWithReview() throws {
        let fixes = Array(raw.prefix(2))
        let threshold = RouteReviewSection.movedThresholdMeters

        let under = try verdicts(
            matched: Array(displaced(by: threshold / 2).prefix(2)),
            fixes: fixes
        )
        #expect(!under.reviewed)
        #expect(under.saved == under.reviewed)

        let past = try verdicts(
            matched: Array(displaced(by: threshold * 2).prefix(2)),
            fixes: fixes
        )
        #expect(past.reviewed)
        #expect(past.saved == past.reviewed)

        // One point more than the fixes, and every pair the two share still
        // lines up within the threshold: only the count rule calls it moved.
        let last = fixes[1]
        let extra = try verdicts(
            matched: fixes + [
                point(last.latitude + threshold / 2 / metersPerDegree, last.longitude, at: 61),
            ],
            fixes: fixes
        )
        #expect(extra.reviewed)
        #expect(extra.saved == extra.reviewed)
    }

    /// What review and the save each make of one leg drawn as `matched`
    /// across `fixes`: whether review calls it moved, and whether the
    /// prepared hike keeps a raw trace.
    private func verdicts(
        matched: [RecordingPoint],
        fixes: [RecordingPoint]
    ) throws -> (reviewed: Bool, saved: Bool) {
        let leg = TrailMatchLeg(
            index: 0,
            defaultPoints: matched,
            rawPoints: fixes,
            alternatives: [],
            trailNames: ["Ridge Path"]
        )
        let match = TrailMatchResult(
            points: matched,
            matchedLegCount: 1,
            ambiguousLegCount: 0,
            matchedTrailName: "Ridge Path",
            currentTrail: nil,
            didMoveRoute: false,
            ambiguities: [],
            legs: [leg]
        )
        let prepared = try RecordingPreparation.prepareResolved(
            points: fixes,
            startedAt: start,
            matchResult: match,
            choices: [0: .matched]
        )
        return (RouteReviewSection.legMoved(leg), !prepared.rawRoute.isEmpty)
    }
}
