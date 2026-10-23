//
//  RouteProfilePausedTransferTests.swift
//  OpenHikesDataTests
//
//  A pause is not distance (#962). The ground between the fix before a pause
//  and the fix after it was crossed by car, by lift or not at all, and the
//  recorder and the watch already leave it out of a walk's length. The
//  profile used to walk straight across it: a 222 m walk with a kilometre's
//  drive in the middle was a 1,223 m trail, and a fix in the middle of the
//  drive matched the trail at 0 m off-route.
//
//  So a paused leg has no length on the profile's axis — the two recorded
//  pieces meet at one distance, where the chart steps — and nothing is ever
//  matched onto it.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("A paused transfer on the route profile")
struct RouteProfilePausedTransferTests {
    /// One thousandth of a degree of longitude on the equator, by the same
    /// great-circle arithmetic the profile uses.
    private static let step = RouteGeometry.distanceMeters(
        from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        to: CLLocationCoordinate2D(latitude: 0, longitude: 0.001)
    )

    /// Points along the equator at `longitudes`, the ones named in `resumed`
    /// arriving after a pause, carrying `elevations` when there are any.
    private static func route(
        _ longitudes: [Double],
        resumingAt resumed: Set<Int>,
        elevations: [Double?] = []
    ) -> [RouteCoordinate] {
        longitudes.enumerated().map { index, longitude in
            RouteCoordinate(
                latitude: 0,
                longitude: longitude,
                elevation: elevations.isEmpty ? nil : elevations[index],
                boundary: resumed.contains(index) ? .paused : nil
            )
        }
    }

    /// The issue's own case: 111 m walked, a kilometre driven, 111 m walked.
    private static let transfer = route([0, 0.001, 0.010, 0.011], resumingAt: [2])

    private static func at(_ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 0, longitude: longitude)
    }

    // MARK: - Distance

    @Test("a long paused transfer adds nothing to the route's length")
    func longTransferAddsNoDistance() {
        let profile = RouteProfile(route: Self.transfer)

        #expect(profile.totalDistanceMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
        #expect(profile.distances[2] == profile.distances[1])
        #expect(profile.pauseDistances == [profile.distances[1]])
    }

    @Test("a pause that moved nowhere marks the join and changes nothing else")
    func zeroDistancePause() {
        let profile = RouteProfile(route: Self.route([0, 0.001, 0.001, 0.002], resumingAt: [2]))

        #expect(profile.totalDistanceMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
        #expect(profile.pauseDistances.count == 1)
        #expect(profile.pauseDistances.first?.isApproximatelyEqual(to: Self.step, absoluteTolerance: 0.01) == true)
    }

    @Test("every pause is left out, and each marks where its pieces meet")
    func multiplePauses() throws {
        let profile = RouteProfile(
            route: Self.route([0, 0.001, 0.010, 0.011, 0.020, 0.021], resumingAt: [2, 4])
        )

        #expect(profile.totalDistanceMeters.isApproximatelyEqual(to: 3 * Self.step, absoluteTolerance: 0.01))
        try #require(profile.pauseDistances.count == 2)
        #expect(profile.pauseDistances[0].isApproximatelyEqual(to: Self.step, absoluteTolerance: 0.01))
        #expect(profile.pauseDistances[1].isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
    }

    /// Two pauses with a single fix between them meet at one distance; the
    /// chart draws one rule there, and a rule identified by its distance must
    /// not be listed twice.
    @Test("two pauses that meet at one distance are one rule")
    func pausesAtOneDistanceAreOneRule() {
        let profile = RouteProfile(route: Self.route([0, 0.001, 0.010, 0.020, 0.021], resumingAt: [2, 3]))

        #expect(profile.pauseDistances.count == 1)
        #expect(profile.totalDistanceMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
    }

    /// What a GPX import saves as the hike's distance, so the detail screen's
    /// figure and the chart's axis are one number.
    @Test("a stored route's length leaves the pause out too, and is the profile's length")
    func lengthAgreesWithTheProfile() {
        let profile = RouteProfile(route: Self.transfer)

        #expect(Self.transfer.lengthMeters.isApproximatelyEqual(to: 2 * Self.step, absoluteTolerance: 0.01))
        #expect(Self.transfer.lengthMeters.isApproximatelyEqual(
            to: profile.totalDistanceMeters,
            absoluteTolerance: 0.001
        ))
    }

    // MARK: - Interpolation

    @Test("the pause's own distance is the fix before it, and either side is its own piece")
    func interpolationAtTheBoundary() throws {
        let profile = RouteProfile(route: Self.transfer)
        let pause = try #require(profile.pauseDistances.first)

        let atPause = try #require(profile.coordinate(atDistance: pause))
        #expect(atPause.longitude.isApproximatelyEqual(to: 0.001, absoluteTolerance: 1e-9))

        let before = try #require(profile.coordinate(atDistance: pause - Self.step / 2))
        #expect(before.longitude.isApproximatelyEqual(to: 0.0005, absoluteTolerance: 1e-6))

        let after = try #require(profile.coordinate(atDistance: pause + Self.step / 2))
        #expect(after.longitude.isApproximatelyEqual(to: 0.0105, absoluteTolerance: 1e-6))
    }

    // MARK: - Matching

    @Test("a fix in the middle of the transfer is not on the trail")
    func fixInsideTheSkippedLegIsOffRoute() throws {
        let profile = RouteProfile(route: Self.transfer)

        let match = try #require(profile.nearestPoint(to: Self.at(0.005)))

        #expect(match.offRouteMeters > RouteProfile.followMatchThresholdMeters)
    }

    @Test("continuity cannot pull a fix onto the transfer either")
    func continuityDoesNotMatchTheSkippedLeg() throws {
        let profile = RouteProfile(route: Self.transfer)
        let pause = try #require(profile.pauseDistances.first)

        let windowed = try #require(profile.nearestPoint(to: Self.at(0.005), near: pause, scope: .continuityWindow))
        #expect(windowed.offRouteMeters > RouteProfile.followMatchThresholdMeters)

        let headingFirst = try #require(profile.nearestPointHeadingFirst(to: Self.at(0.005), near: pause, heading: 90))
        #expect(headingFirst.offRouteMeters > RouteProfile.followMatchThresholdMeters)
    }

    @Test("a fix on the piece after the pause matches it on the walked axis")
    func fixAfterThePauseMatchesThePieceAfterIt() throws {
        let profile = RouteProfile(route: Self.transfer)
        let pause = try #require(profile.pauseDistances.first)

        let match = try #require(profile.nearestPoint(to: Self.at(0.0105)))

        #expect(match.offRouteMeters < 1)
        #expect(match.distanceAlongRoute.isApproximatelyEqual(to: pause + Self.step / 2, absoluteTolerance: 0.5))
    }

    /// The join's own distance reads as the fix before the pause, so a fix
    /// that projects onto the very start of the next piece — a hiker standing
    /// a few metres short of where the recording resumed, back at the second
    /// trailhead — is placed just past it, on its own piece, rather than a
    /// drive away at the other end of the pause.
    @Test("a fix at the start of the piece after a pause is placed on that piece")
    func fixAtTheResumeIsPlacedOnItsOwnPiece() throws {
        let profile = RouteProfile(route: Self.transfer)

        let match = try #require(profile.nearestPoint(to: Self.at(0.0098)))
        let placed = try #require(profile.coordinate(atDistance: match.distanceAlongRoute))

        #expect(match.offRouteMeters < RouteProfile.followMatchThresholdMeters)
        #expect(placed.longitude.isApproximatelyEqual(to: 0.010, absoluteTolerance: 1e-6))
    }

    // MARK: - Drawing what was covered

    @Test("a covered stretch across a pause is drawn as two pieces, not across the drive")
    func coveredStretchSplitsAtThePause() throws {
        let profile = RouteProfile(route: Self.transfer)
        let pause = try #require(profile.pauseDistances.first)

        let pieces = profile.stretches(covering: (pause - Self.step / 2)...(pause + Self.step / 2))

        try #require(pieces.count == 2)
        #expect(pieces[0].first?.longitude.isApproximatelyEqual(to: 0.0005, absoluteTolerance: 1e-6) == true)
        #expect(pieces[0].last?.longitude.isApproximatelyEqual(to: 0.001, absoluteTolerance: 1e-9) == true)
        #expect(pieces[1].first?.longitude.isApproximatelyEqual(to: 0.010, absoluteTolerance: 1e-9) == true)
        #expect(pieces[1].last?.longitude.isApproximatelyEqual(to: 0.0105, absoluteTolerance: 1e-6) == true)
    }

    @Test("a covered stretch that starts at the join starts on the piece after it")
    func coveredStretchFromTheJoinStartsAfterIt() throws {
        let profile = RouteProfile(route: Self.transfer)
        let pause = try #require(profile.pauseDistances.first)

        let pieces = profile.stretches(covering: pause...(pause + Self.step / 2))

        try #require(pieces.count == 1)
        #expect(pieces[0].first?.longitude.isApproximatelyEqual(to: 0.010, absoluteTolerance: 1e-9) == true)
        #expect(pieces[0].last?.longitude.isApproximatelyEqual(to: 0.0105, absoluteTolerance: 1e-6) == true)
    }

    @Test("a covered stretch with no pause in it is one piece through every point")
    func coveredStretchWithoutAPause() throws {
        let profile = RouteProfile(route: Self.route([0, 0.001, 0.002, 0.003], resumingAt: []))

        let pieces = profile.stretches(covering: (Self.step / 2)...(2.5 * Self.step))

        try #require(pieces.count == 1)
        #expect(pieces[0].map(\.longitude).count == 4)
        #expect(pieces[0][1].longitude == 0.001)
        #expect(pieces[0][2].longitude == 0.002)
    }

    /// A route can end on a pause: a recording resumed and stopped on its
    /// next fix, or a GPX file whose last segment is one point. That point
    /// stands at the route's last distance, beside the fix before the pause,
    /// and the end reads as that fix like any other join does. Otherwise a
    /// hiker at the end of the walked line is drawn a drive away, and a walk
    /// that covered the whole route is drawn across the drive.
    @Test("a route that ends on a pause ends where the walking did")
    func routeEndingOnAPause() throws {
        let profile = RouteProfile(route: Self.route(
            [0, 0.001, 0.002, 0.010],
            resumingAt: [3],
            elevations: [100, 110, 120, 500]
        ))
        let total = profile.totalDistanceMeters

        let atEnd = try #require(profile.coordinate(atDistance: total))
        #expect(atEnd.longitude.isApproximatelyEqual(to: 0.002, absoluteTolerance: 1e-9))
        #expect(profile.sample(atDistance: total)?.elevation == 120)

        let match = try #require(profile.nearestPoint(to: Self.at(0.002)))
        let placed = try #require(profile.coordinate(atDistance: match.distanceAlongRoute))
        #expect(placed.longitude.isApproximatelyEqual(to: 0.002, absoluteTolerance: 1e-9))

        // Also for a range stored on a longer axis, which reaches past the end.
        for upper in [total, total + 500] {
            let drawn = profile.stretches(covering: 0...upper).joined()
            #expect(!drawn.isEmpty)
            #expect(drawn.allSatisfy { $0.longitude < 0.005 }, "nothing drawn across the drive")
        }
    }

    @Test("a route whose every leg is a pause has nothing to match against")
    func onlyPausedLegsMatchNothing() {
        let profile = RouteProfile(route: Self.route([0, 0.010], resumingAt: [1]))

        #expect(profile.nearestPoint(to: Self.at(0.005)) == nil)
    }

    // MARK: - The chart

    @Test("the chart steps at the join, with both heights plotted and told apart")
    func chartStepsAtTheJoin() throws {
        let profile = RouteProfile(route: Self.route(
            [0, 0.001, 0.010, 0.011],
            resumingAt: [2],
            elevations: [100, 110, 500, 510]
        ))
        let pause = try #require(profile.pauseDistances.first)

        let atPause = profile.samples.filter { $0.distanceMeters == pause }
        #expect(atPause.map(\.elevation) == [110, 500])
        #expect(Set(profile.samples.map(\.id)).count == profile.samples.count)
    }
}
