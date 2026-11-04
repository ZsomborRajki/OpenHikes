//
//  TrailWalkStandstillTests.swift
//  OpenHikesDataTests
//
//  A hiker standing still while their fixes wander along the route. Every
//  fix lands within its own accuracy of them, and a walk accepts fixes good
//  only to 75 m, so two of them can be further apart than a turn without a
//  step taken. Measured against the turn alone, the walk turned on every
//  swing, and its time left with it (#1307). A turn is weighed against the
//  two fixes' accuracies as well — and never past the gap bound, so a sparse
//  feed's single jump still says which way at once.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import Testing

@Suite("Trail walk standstill")
struct TrailWalkStandstillTests {
    private static let turn = TrailWalkPolicy.minimumTurnMeters
    private static let metersPerDegreeLatitude = 111_320.0
    private static let metersPerDegreeLongitude = 111_320.0 * cos(47 * Double.pi / 180)

    private static func point(north: Double, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 47 + north / metersPerDegreeLatitude,
            longitude: 12 + east / metersPerDegreeLongitude
        )
    }

    /// Two kilometres due north, a point every ten metres.
    private static let profile = RouteProfile(route: (0...200).map { index in
        RouteCoordinate(point(north: Double(index) * 10))
    })

    /// Matches every `step` metres from `start` to `end`, of fixes good to
    /// `accuracy`.
    private func walk(
        from start: Double,
        to end: Double,
        accuracy: Double,
        into coverage: inout TrailWalkCoverage,
        step: Double = 20
    ) {
        var distance = start
        let direction: Double = end >= start ? 1 : -1
        while direction * (end - distance) > 0 {
            coverage.record(distance: distance, accuracy: accuracy)
            distance += direction * step
        }
        coverage.record(distance: end, accuracy: accuracy)
    }

    /// The probe from #1299's review, on the matcher both feeds use: up the
    /// trail on good fixes, then standing at the kilometre while fixes good to
    /// 70 m swing either side. The matcher's tie-break pulls each match
    /// towards the last, so only the wider swings land a turn apart — and
    /// each of those turned the walk.
    @Test("fixes wandering within their accuracy at a standstill do not turn the walk")
    func aStandstillDoesNotTurnTheWalk() throws {
        let accuracy = 70.0
        let standing = Self.point(north: 1000)
        var coverage = TrailWalkCoverage()
        var reference: Double?
        for north in stride(from: 0.0, through: 1000, by: 20) {
            let match = try #require(Self.profile.nearestPoint(to: Self.point(north: north), near: reference))
            coverage.record(distance: match.distanceAlongRoute, accuracy: 5)
            reference = match.distanceAlongRoute
        }
        try #require(coverage.direction == .towardsEnd)

        let swings: [(north: Double, east: Double)] = [
            (40, 10), (-42, -12), (60, 20), (-60, -20), (62, 10), (-62, 0),
            (65, 5), (-64, -10), (66, 0), (-65, 8), (64, -12), (-66, 0),
        ]
        var matched: [Double] = []
        for swing in swings {
            let fix = Self.point(north: 1000 + swing.north, east: swing.east)
            try #require(RouteGeometry.distanceMeters(from: fix, to: standing) <= accuracy)
            let match = try #require(Self.profile.nearestPoint(to: fix, near: reference))
            coverage.record(distance: match.distanceAlongRoute, accuracy: accuracy)
            reference = match.distanceAlongRoute
            matched.append(match.distanceAlongRoute)
            #expect(coverage.direction == .towardsEnd, "matched at \(match.distanceAlongRoute)")
        }
        let spread = try #require(matched.max()) - (try #require(matched.min()))
        #expect(spread >= Self.turn, "precondition: the matches are a turn apart, \(spread) m")
    }

    /// End to end: a hiker standing still can have one fix at the far edge of
    /// its accuracy and the next at the near edge of its own.
    @Test("a turn is the two fixes' accuracies end to end, and never less than a turn", arguments: [
        (0.0, 0.0, 75.0),
        (30.0, 30.0, 75.0),
        (40.0, 40.0, 80.0),
        (60.0, 40.0, 100.0),
        (40.0, 60.0, 100.0),
        (75.0, 75.0, 150.0),
    ])
    func aTurnWeighsBothFixes(reachedAccuracy: Double, accuracy: Double, turn: Double) {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 1000, accuracy: reachedAccuracy, into: &coverage)
        #expect(coverage.direction == .towardsEnd)

        coverage.record(distance: 1000 - turn + 1, accuracy: accuracy)
        #expect(coverage.direction == .towardsEnd, "not yet")
        coverage.record(distance: 1000 - turn, accuracy: accuracy)
        #expect(coverage.direction == .towardsStart)
    }

    /// The trade-off #1299 made and #1307 keeps: a significant-change feed may
    /// deliver nothing but jumps past the gap bound, and each of them has to
    /// say which way the walk is going on its own, however poor its fix.
    @Test("a jump past the gap bound still turns the walk at once, however uncertain", arguments: [75.0, 400.0])
    func aJumpStillTurnsTheWalk(accuracy: Double) {
        var sparse = TrailWalkCoverage()
        for distance in [5000.0, 4400, 3800] {
            sparse.record(distance: distance, accuracy: accuracy)
        }
        #expect(sparse.coveredMeters == 0)
        #expect(sparse.direction == .towardsStart)

        var turned = TrailWalkCoverage()
        walk(from: 0, to: 2000, accuracy: accuracy, into: &turned)
        #expect(turned.direction == .towardsEnd)
        turned.record(distance: 2000 - TrailWalkPolicy.gapBoundMeters - 1, accuracy: accuracy)
        #expect(turned.direction == .towardsStart)
    }

    /// What a relaunch reads: a turn counts from where the last write left it,
    /// and against the fix it was measured from. Read as a fix that said
    /// nothing, the first backstep after the relaunch would be a turn.
    @Test("how good the fix a turn counts from was comes back with the record")
    func theAccuracySurvivesTheRecord() throws {
        var record = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: 6000,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        walk(from: 0, to: 1000, accuracy: 60, into: &record.coverage)

        var restored = try JSONDecoder().decode(TrailWalkRecord.self, from: JSONEncoder().encode(record))

        #expect(restored == record)
        restored.coverage.record(distance: 900, accuracy: 60)
        #expect(restored.coverage.direction == .towardsEnd)
        restored.coverage.record(distance: 880, accuracy: 60)
        #expect(restored.coverage.direction == .towardsStart)
    }
}
