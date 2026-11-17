//
//  TrailWalkSessionTests+OffTrailQuestion.swift
//  OpenHikesTests
//
//  A hiker who has left the trail they are walking is asked whether to go on
//  following it or to record instead — see ``OffTrailQuestion``.
//
//  When to ask is the reminder controller's, and its own suite holds that.
//  These hold the session's half: that the question is about the walk under
//  way and stands only while that walk is following off its trail, that
//  *Keep Following* changes nothing but the question, and what *Record
//  Instead* takes from the walk on its way out.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

extension TrailWalkSessionTests {
    /// Comfortably past ``MovementReminderPolicy/offTrailMeters``.
    private static let wellOff = 400.0

    private func askingSession(_ harness: MovementReminderHarness.Harness) -> TrailWalkSession {
        TrailWalkSession(context: context, reminders: harness.controller, clock: clock.read)
    }

    /// A walk under way along seven points of the trail, as a hiker makes
    /// one: a minute a point.
    private func walking(_ session: TrailWalkSession, along walked: Hike) {
        walk(session, hike: walked, profile: RouteProfile(route: walked.route), from: 0, through: 6)
    }

    /// Two fixes well off the route, the dwell apart: a departure worth
    /// saying.
    private func leaveTheTrail(_ session: TrailWalkSession, hike: Hike) {
        session.recordRouteDistance(hikeID: hike.id, offRouteMeters: Self.wellOff, at: clock.now)
        clock.advance(by: MovementReminderPolicy.offTrailDwell)
        session.recordRouteDistance(hikeID: hike.id, offRouteMeters: Self.wellOff, at: clock.now)
    }

    // MARK: The question

    @Test("leaving the walked trail asks about it, by name")
    func leavingTheTrailAsks() {
        let harness = MovementReminderHarness.harness(clock: clock)
        let session = askingSession(harness)
        let walked = hike()
        walking(session, along: walked)
        #expect(session.offTrailQuestion == nil)

        leaveTheTrail(session, hike: walked)

        #expect(session.offTrailQuestion == OffTrailQuestion(hikeID: walked.id, trailTitle: walked.displayTitle))
    }

    @Test("Keep Following puts the question away and leaves the walk as it was, for the rest of the departure")
    func keepFollowingChangesNothingElse() {
        let harness = MovementReminderHarness.harness(clock: clock)
        let session = askingSession(harness)
        let walked = hike()
        walking(session, along: walked)
        leaveTheTrail(session, hike: walked)
        let covered = session.coveredFraction

        session.keepFollowing()

        #expect(session.offTrailQuestion == nil)
        #expect(session.walkedHikeID == walked.id)
        #expect(session.phase == .following)
        #expect(session.coveredFraction == covered)

        // Still off the trail a quarter of an hour on: the hiker has said.
        clock.advance(by: 900)
        session.recordRouteDistance(hikeID: walked.id, offRouteMeters: Self.wellOff, at: clock.now)
        #expect(session.offTrailQuestion == nil)
    }

    @Test("a hiker who comes back to the trail before answering is not left with the question")
    func rejoiningWithdrawsTheQuestion() {
        let harness = MovementReminderHarness.harness(clock: clock)
        let session = askingSession(harness)
        let walked = hike()
        walking(session, along: walked)
        leaveTheTrail(session, hike: walked)

        clock.advance(by: 60)
        session.recordRouteDistance(hikeID: walked.id, offRouteMeters: 10, at: clock.now)

        #expect(session.offTrailQuestion == nil)
        #expect(session.walkedHikeID == walked.id)
    }

    @Test("a second departure, after being back on the trail, asks again")
    func aSecondDepartureAsksAgain() {
        let harness = MovementReminderHarness.harness(clock: clock)
        let session = askingSession(harness)
        let walked = hike()
        walking(session, along: walked)
        leaveTheTrail(session, hike: walked)
        session.keepFollowing()
        clock.advance(by: 60)
        session.recordRouteDistance(hikeID: walked.id, offRouteMeters: 10, at: clock.now)

        clock.advance(by: 60)
        leaveTheTrail(session, hike: walked)

        #expect(session.offTrailQuestion?.hikeID == walked.id)
    }

    @Test("pausing the walk puts the question away, and a paused walk is not asked")
    func pausingWithdrawsTheQuestion() {
        let harness = MovementReminderHarness.harness(clock: clock)
        let session = askingSession(harness)
        let walked = hike()
        walking(session, along: walked)
        leaveTheTrail(session, hike: walked)

        #expect(session.pause())
        #expect(session.offTrailQuestion == nil)

        session.askAboutLeavingTrail()
        #expect(session.offTrailQuestion == nil, "a paused walk's hiker is somewhere else on purpose")
    }

    @Test("ending the walk puts the question away")
    func endingWithdrawsTheQuestion() {
        let harness = MovementReminderHarness.harness(clock: clock)
        let session = askingSession(harness)
        let walked = hike()
        walking(session, along: walked)
        leaveTheTrail(session, hike: walked)

        session.end()

        #expect(session.offTrailQuestion == nil)
    }

    @Test("with reminders off, leaving the trail asks nothing")
    func remindersOffAsksNothing() {
        let harness = MovementReminderHarness.harness(remindersEnabled: false, clock: clock)
        let session = askingSession(harness)
        let walked = hike()
        walking(session, along: walked)

        leaveTheTrail(session, hike: walked)

        #expect(session.offTrailQuestion == nil)
    }

    // MARK: Recording instead

    /// The question can wait for as long as the phone is in a pocket. The
    /// walk along the trail was over when its hiker left the trail, and what
    /// the recording is handed is clocked over exactly that walk.
    @Test("handing the walk to a recording ends it where it left the trail, and hands over what it covered")
    func handOffEndsTheWalkWhereItLeftTheTrail() async throws {
        let session = session()
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        #expect(session.start(hike: walked, profile: profile))
        let startedAt = clock.now
        walk(session, hike: walked, profile: profile, from: 0, through: 6)
        let lastOnTrail = clock.now
        clock.advance(by: 900)

        let handOff = try #require(await session.handOffToRecording().ended)

        let row = try #require(handOff.end.walk)
        #expect(session.walkedHikeID == nil)
        #expect(try walks(of: walked).count == 1, "kept in the trail's History, as an End keeps it")
        #expect(row.endedAt == lastOnTrail, "not the quarter of an hour later that it was asked about")
        #expect(row.activeSeconds.isApproximatelyEqual(to: 420, absoluteTolerance: 0.001))

        let seed = try #require(handOff.seed)
        #expect(seed.startedAt == startedAt)
        // To the instant, both of them: the recording's clock has to cover
        // the whole of the row for the library to count the ground once.
        #expect(seed.points.first?.timestamp == row.startedAt)
        #expect(seed.points.last?.timestamp == row.endedAt)
    }

    /// A walk adopted at launch has no profile until its hike's screen feeds
    /// it one, and the question can be answered before that: from the banner,
    /// straight into the app.
    @Test("a walk with no profile in hand reads its line to hand over")
    func aWalkAdoptedAtLaunchReadsItsLine() async throws {
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        let opening = session()
        #expect(opening.start(hike: walked, profile: profile))
        walk(opening, hike: walked, profile: profile, from: 0, through: 6)

        let relaunched = session()
        relaunched.restoreAtLaunch()
        #expect(relaunched.walkedHikeID == walked.id)
        #expect(relaunched.walkedProfile == nil, "precondition: nothing has handed it one")
        let startedAt = try #require(relaunched.record?.startedAt)

        let handOff = try #require(await relaunched.handOffToRecording().ended)

        let seed = try #require(handOff.seed)
        #expect(seed.points.count > 1)
        #expect(seed.points.first?.timestamp == startedAt)
        #expect(handOff.end.walk != nil)
    }

    @Test("a walk under the minimum is handed over all the same, and leaves no row")
    func aShortWalkIsStillCarried() async throws {
        let session = session()
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        #expect(session.start(hike: walked, profile: profile))
        // One step of the trail: 56 m, short of what a History row needs.
        walk(session, hike: walked, profile: profile, from: 0, through: 1)

        let handOff = try #require(await session.handOffToRecording().ended)

        #expect(handOff.end.walk == nil)
        #expect(try walks(of: walked).isEmpty)
        #expect(handOff.seed?.points.isEmpty == false, "the ground is the recording's either way")
        #expect(session.walkedHikeID == nil)
    }

    /// Nothing may record beside a walk the store would not end.
    @Test("a walk the store will not end hands nothing over, and is still under way")
    func aRefusedEndHandsNothingOver() async throws {
        var refusing = false
        let session = TrailWalkSession(
            context: context,
            clock: clock.read,
            save: { store in
                if refusing { throw CocoaError(.fileWriteUnknown) }
                try store.save()
            }
        )
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        #expect(session.start(hike: walked, profile: profile))
        walk(session, hike: walked, profile: profile, from: 0, through: 6)
        refusing = true

        let handOff = try #require(await session.handOffToRecording().ended)

        guard case .refused = handOff.end else {
            Issue.record("a store that refuses the commit must refuse the hand-off")
            return
        }
        #expect(handOff.seed == nil)
        #expect(session.walkedHikeID == walked.id)
    }

    @Test("with no walk under way there is nothing to hand over")
    func noWalkHandsNothingOver() async {
        guard case .noWalk = await session().handOffToRecording() else {
            Issue.record("with no walk, nothing is ended and nothing carried")
            return
        }
    }
}
