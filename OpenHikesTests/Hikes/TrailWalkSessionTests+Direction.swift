//
//  TrailWalkSessionTests+Direction.swift
//  OpenHikesTests
//
//  The end of the trail the walk under way is timing, as the session hands it
//  on: the readout and the payload, the after-dark reminder, and a relaunch,
//  which finds the way the walk was going where the last write left it
//  (#1195). The distance as well as the climb is the way to that end (#1304).
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import Testing

extension TrailWalkSessionTests {
    private func climbingHike() -> Hike {
        Fixture.hike(in: context, title: "Summit Path", route: WalkTimeLeftDirectionTests.route)
    }

    /// Feeds one match at `distance`, `seconds` after the last.
    private func match(
        _ session: TrailWalkSession,
        hike: Hike,
        profile: RouteProfile,
        at distance: Double,
        after seconds: TimeInterval = 60
    ) {
        clock.advance(by: seconds)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: distance)
    }

    @Test("a walk that turned back is timed towards the start, at its own pace")
    func aTurnedWalkIsTimedBack() throws {
        let session = session()
        let walked = climbingHike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 80)
        walk(session, hike: walked, profile: profile, from: 79, through: 65)

        let record = try #require(session.record)
        let stretch = try #require(profile.climb(from: 0, to: profile.distances[65]))
        let pace = try #require(WalkTimeLeft.paceFactor(
            profile: profile,
            coverage: record.coverage,
            activeSeconds: record.activeSeconds(at: clock.read())
        ))
        // The 6.5 km back to the start, not the 2 km beyond the turn the
        // walk never covered (#1304).
        let signposts = WalkingTimeEstimate.seconds(
            distanceMeters: profile.distances[65],
            ascentMeters: stretch.lossMeters,
            descentMeters: stretch.gainMeters
        )

        let left = try #require(session.secondsLeft())
        #expect(left.isApproximatelyEqual(to: signposts * pace, absoluteTolerance: 0.001))
        #expect(session.payload(for: walked.id)?.secondsLeft == left)
        // And the readout beside it, on the detail and on the Lock Screen,
        // says the distance it times.
        #expect(session.metersLeft.isApproximatelyEqual(to: profile.distances[65], absoluteTolerance: 0.001))
        #expect(session.payload(for: walked.id)?.metersLeft == session.metersLeft)
    }

    /// The issue's walk, against a dusk between the two answers: the 2 km
    /// the walk never covered end in daylight, and the 6.5 km back to the
    /// start do not, so only the way back can say so (#1304).
    @Test("a walk that turned back is warned of a dusk it meets on the way back")
    func aTurnedWalkIsWarnedOfTheWayBack() async throws {
        let harness = MovementReminderHarness.harness(clock: clock)
        var dusk: Date?
        let session = TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read,
            daylight: { _, _ in WeatherDaylight(civilDusk: dusk) }
        )
        let walked = climbingHike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 80)
        walk(session, hike: walked, profile: profile, from: 79, through: 65)

        let record = try #require(session.record)
        let position = profile.distances[65]
        let pace = try #require(WalkTimeLeft.paceFactor(
            profile: profile,
            coverage: record.coverage,
            activeSeconds: record.activeSeconds(at: clock.read())
        ))
        let down = try #require(profile.climb(from: 0, to: position))
        let atPace = { (meters: Double) in
            WalkingTimeEstimate.seconds(
                distanceMeters: meters,
                ascentMeters: down.lossMeters,
                descentMeters: down.gainMeters
            ) * pace
        }
        let uncovered = atPace(record.routeDistanceMeters - record.coverage.coveredMeters)
        let wayBack = atPace(position)
        #expect(wayBack - uncovered > 20 * 60, "precondition: room for a minute's drift either side of dusk")
        dusk = clock.read().addingTimeInterval(60 + (uncovered + wayBack) / 2)

        match(session, hike: walked, profile: profile, at: position)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.afterDark])
    }

    /// A walk confirmed by movement has moved further than a turn, so the
    /// first estimate it ever makes already knows which way it is going.
    @Test("a walk that starts by moving starts knowing which way")
    func aConfirmedWalkKnowsItsWay() throws {
        let session = session()
        let walked = climbingHike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 60, through: 57)

        #expect(try #require(session.record).coverage.direction == .towardsStart)
    }

    /// The miss that matters. Down from the 3 km point to the 1.5 km point
    /// the walk ends in daylight. Then the hiker turns for the summit, and
    /// 300 m on the coverage still put them on the way down, so nothing
    /// warned of the 1000 m ahead of them. Dusk sits between the two finishes.
    @Test("a turn towards the climb that ends after dusk is warned of")
    func aTurnTowardsTheClimbIsWarned() async {
        let harness = MovementReminderHarness.harness(clock: clock)
        let dusk = clock.read().addingTimeInterval(175 * 60)
        let session = TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read,
            daylight: { _, _ in WeatherDaylight(civilDusk: dusk) }
        )
        let walked = climbingHike()
        let profile = RouteProfile(route: walked.route)

        walk(session, hike: walked, profile: profile, from: 30, through: 15)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty, "on the way down, the walk ends in daylight")

        walk(session, hike: walked, profile: profile, from: 16, through: 18)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.afterDark])
    }

    /// A minute between fixes is past the write cadence, so the sidecar is up
    /// to date. The first fix after the relaunch is a backstep, which is not
    /// enough to turn a walk the sidecar says is going down.
    @Test("a relaunch finds the way the walk was going in the sidecar")
    func aRelaunchKeepsTheWay() throws {
        let walked = climbingHike()
        let profile = RouteProfile(route: walked.route)
        let first = session()
        walk(first, hike: walked, profile: profile, from: 0, through: 80)
        walk(first, hike: walked, profile: profile, from: 79, through: 65)
        #expect(try #require(walked.walkInProgress).coverage.direction == .towardsStart)

        let relaunched = session()
        relaunched.restoreAtLaunch()
        #expect(try #require(relaunched.record).coverage.direction == .towardsStart)

        match(relaunched, hike: walked, profile: profile, at: profile.distances[65] + 40)
        let coverage = try #require(relaunched.record).coverage
        #expect(coverage.direction == .towardsStart)
        let ahead = try #require(WalkTimeLeft.climbAhead(
            profile: profile,
            position: profile.distances[65] + 40,
            coverage: coverage
        ))
        #expect(ahead.gainMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
    }

    /// The write is at the cadence, so a relaunch can lose the last of it.
    /// What a turn counts from is written with the way, so a hiker who turned
    /// in the fixes it lost is caught by the first fix after it, rather than
    /// after another turn's length.
    @Test("a turn the last write missed is caught by the first fix after a relaunch")
    func aRelaunchCatchesAnUnwrittenTurn() throws {
        let walked = climbingHike()
        let profile = RouteProfile(route: walked.route)
        let first = session()
        walk(first, hike: walked, profile: profile, from: 0, through: 80)
        let top = profile.distances[80]

        match(first, hike: walked, profile: profile, at: top - 50, after: 10)
        match(first, hike: walked, profile: profile, at: top - 100, after: 10)
        #expect(try #require(first.record).coverage.direction == .towardsStart)
        #expect(
            try #require(walked.walkInProgress).coverage.direction == .towardsEnd,
            "precondition: the turn is inside the write window"
        )

        let relaunched = session()
        relaunched.restoreAtLaunch()
        match(relaunched, hike: walked, profile: profile, at: top - 110, after: 10)

        #expect(try #require(relaunched.record).coverage.direction == .towardsStart)
    }

    /// The hiker turned on the way to the pause and is still going down
    /// after it, and a fix behind the pause spot does not change that either.
    @Test("a pause keeps the way the walk was going")
    func aPauseKeepsTheWay() throws {
        let session = session()
        let walked = climbingHike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 80)
        walk(session, hike: walked, profile: profile, from: 79, through: 65)

        session.pause()
        clock.advance(by: 600)
        session.resume()
        match(session, hike: walked, profile: profile, at: profile.distances[70])
        #expect(try #require(session.record).coverage.direction == .towardsStart, "a fix is no turn after a break")

        match(session, hike: walked, profile: profile, at: profile.distances[70] + 74)
        #expect(try #require(session.record).coverage.direction == .towardsStart)
        match(session, hike: walked, profile: profile, at: profile.distances[70] + 80)
        #expect(try #require(session.record).coverage.direction == .towardsEnd)
    }
}
