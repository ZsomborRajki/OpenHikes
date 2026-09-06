//
//  TrailWalkSessionTests+Reminders.swift
//  OpenHikesTests
//
//  That a paused walk still hears the fixes that keep arriving, and that
//  walking the trail with the walk paused is noticed.
//
//  The walk's half of this feature costs no sensor at all: the matched fixes
//  the detail screen and the background tracker were already feeding in are
//  the measurement — see ``MovementReminderController/walkDidPause(trailTitle:atDistance:)``.
//  What these pin is that the paused branch of `recordMatch` really does hand
//  them on, and that a pause restored from the sidecar arms the same reminder
//  a tapped one does.
//

import Foundation
@testable import OpenHikes
import Testing

extension TrailWalkSessionTests {
    private func remindingSession(
        _ harness: MovementReminderHarness.Harness
    ) -> TrailWalkSession {
        TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read
        )
    }

    @Test("covering the trail with the walk paused posts a reminder")
    func pausedWalkRemindsWhenTheTrailIsCovered() async {
        let harness = MovementReminderHarness.harness()
        let session = remindingSession(harness)
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 1)
        #expect(session.pause())

        // Nineteen more matched fixes a minute apart: about a kilometre of
        // trail, which crosses the five-hundred-metre rule once and is short
        // of the quarter of an hour a second reminder would also need.
        walk(session, hike: walked, profile: profile, from: 2, through: 20)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeWalk])
        #expect(session.phase == .paused, "the reminder asks; it does not resume anything")
    }

    @Test("resuming the walk takes its reminder down")
    func resumingTheWalkWithdraws() async {
        let harness = MovementReminderHarness.harness()
        let session = remindingSession(harness)
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 1)
        #expect(session.pause())

        #expect(session.resume())
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.resumeWalk))
    }

    /// The pause a walker actually forgets is the one their phone has been in
    /// a pocket through — which, across a background relaunch, is a pause this
    /// process never saw happen.
    @Test("a paused walk restored at launch is watched too")
    func restoredPauseIsArmed() async {
        let harness = MovementReminderHarness.harness()
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        let opening = remindingSession(harness)
        walk(opening, hike: walked, profile: profile, from: 0, through: 1)
        #expect(opening.pause())

        let relaunched = remindingSession(harness)
        relaunched.restoreAtLaunch()
        #expect(relaunched.phase == .paused, "the sidecar is what carries the pause across")
        walk(relaunched, hike: walked, profile: profile, from: 2, through: 20)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds.contains(.resumeWalk))
    }
}
