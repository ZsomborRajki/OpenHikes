//
//  TrailWalkSessionTests+Reminders.swift
//  OpenHikesTests
//
//  That a paused walk still hears the fixes that keep arriving, and that
//  walking the trail with the walk paused is noticed.
//
//  The walk's half of this feature costs no sensor at all: the matched fixes
//  the detail screen and the background tracker were already feeding in are
//  the measurement — see ``MovementReminderController/walkDidPause(trailTitle:atDistance:on:)``.
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

    /// The walker went out to the summit, came back down, and paused at the
    /// hut on the way. Anchoring at the coverage *maximum* rather than at
    /// where they stopped told them, on the very next fix and while standing
    /// still, that they had covered the distance back down the hill.
    @Test("a walk that backtracked before pausing is anchored where it stopped")
    func backtrackedWalkIsAnchoredAtThePausePosition() async {
        let harness = MovementReminderHarness.harness()
        let session = remindingSession(harness)
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        // Out to the far end of the outbound leg, then back down to near the
        // trailhead — the same trail, walked the way it is not stored.
        walk(session, hike: walked, profile: profile, from: 0, through: 19)
        walk(session, hike: walked, profile: profile, from: 18, through: 6)
        #expect(session.pause())

        // Standing still: the same position, matched again.
        clock.advance(by: 60)
        session.recordForegroundMatch(
            hike: walked,
            profile: profile,
            distance: profile.distances[6]
        )
        await harness.controller.settle()

        #expect(
            harness.notifier.posted.isEmpty,
            "a walker who has not moved since pausing has not resumed anything"
        )
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

    /// The bug this pins: the background feed matches asynchronously, so a
    /// fix taken before a newer foreground one can be handed over after it —
    /// and after the Pause it happened before. Delivered as evidence, it says
    /// the walker covered the distance back to where they were half a walk
    /// ago, and it drags the walk's last-seen time backwards with it.
    @Test("a match overtaken by a newer one reminds nobody and does not age the walk")
    func overtakenMatchIsRejected() async {
        let harness = MovementReminderHarness.harness()
        let session = remindingSession(harness)
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 14)
        let overtaken = clock.now

        // A newer foreground match, back down the trail, and the Pause taken
        // there — the walker is standing where this leaves them.
        clock.advance(by: 60)
        session.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[4])
        #expect(session.pause())

        // The background feed finally delivers the older fix.
        session.recordBackgroundMatch(
            hikeID: walked.id,
            distance: profile.distances[14],
            at: overtaken
        )
        await harness.controller.settle()

        #expect(
            harness.notifier.posted.isEmpty,
            "the walker moved before the pause, not since it"
        )
        #expect(
            session.record?.lastMatchedAt == clock.now,
            "and a stale fix does not make the walk older than it is"
        )
    }

    /// The foreground loop's own version of the same hazard, and the one the
    /// clock cannot see: a fix is accepted for matching up to
    /// ``LocationFixPolicy/foregroundMaximumAge`` after it was taken, so the
    /// loop can read a pre-pause fix a second after the walker tapped Pause.
    @Test("a foreground fix taken before the pause is not movement since it")
    func prePauseForegroundFixIsRejected() async {
        let harness = MovementReminderHarness.harness()
        let session = remindingSession(harness)
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 4)
        let lastMatch = clock.now
        clock.advance(by: 60)
        #expect(session.pause())

        // Taken half a minute before the Pause, half a kilometre up the
        // trail, and read by the follow loop twenty seconds after it.
        clock.advance(by: 20)
        session.recordForegroundMatch(
            hike: walked,
            profile: profile,
            distance: profile.distances[14],
            at: lastMatch.addingTimeInterval(30)
        )
        await harness.controller.settle()

        #expect(
            harness.notifier.posted.isEmpty,
            "the walker walked that stretch before they stopped"
        )
    }
}
