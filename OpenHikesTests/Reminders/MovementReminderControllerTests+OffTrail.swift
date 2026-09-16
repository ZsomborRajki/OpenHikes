//
//  MovementReminderControllerTests+OffTrail.swift
//  OpenHikesTests
//
//  The fourth reminder, and the one that is not about a pause.
//
//  The other three are bookkeeping — the app and the hiker disagree about
//  whether a walk is happening, and a button settles it. This one tells a
//  hiker walking a route that they are no longer on it, which is worth the
//  most at the moment the phone is in a pocket and nobody is looking at a
//  Lock Screen status word.
//
//  What these pin is the half that decides *when* to say it. Both feeds
//  already computed "is the hiker on the route" before this existed; nothing
//  told them, and the risk in telling them is a banner that cries wolf. So
//  the threshold, the dwell, the once-per-departure rule and what re-arms it
//  are the whole of the feature, and every one of them is a function of what
//  the watch has been told.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementReminderControllerTests {
    private static let trail = "Ridge Loop"
    /// Comfortably past ``MovementReminderPolicy/offTrailMeters``.
    private static let wellOff = 400.0
    /// Inside ``MovementReminderPolicy/onTrailAgainMeters``.
    private static let onTheLine = 20.0
    private static let dwell = MovementReminderPolicy.offTrailDwell

    private func observe(
        _ harness: MovementReminderHarness.Harness,
        offRouteMeters: Double?,
        after seconds: TimeInterval
    ) {
        harness.controller.walkObserved(
            offRouteMeters: offRouteMeters,
            trailTitle: Self.trail,
            at: start.addingTimeInterval(seconds)
        )
    }

    // MARK: Saying it

    @Test("walking off the trail and staying off posts the reminder")
    func leavingTheTrailPostsTheReminder() async {
        let harness = MovementReminderHarness.harness()

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.leftTheTrail])
        #expect(harness.notifier.posted.first?.body.contains(Self.trail) == true)
    }

    /// The dwell is the half a distance cannot do. One fix at 400 m is as
    /// likely to be a bad fix as a wrong turn, and a banner for it is the app
    /// crying wolf at somebody standing on the path.
    @Test("one fix off the line says nothing")
    func aSingleFixSaysNothing() async {
        let harness = MovementReminderHarness.harness()

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// `offTrailMeters` is its own number rather than the tracker's display
    /// threshold, and this is the gap between them: a hiker on a switchback
    /// or a parallel forest road is legitimately this far off the line.
    @Test("a hiker inside the off-trail threshold is not told")
    func staysQuietInsideTheThreshold() async {
        let harness = MovementReminderHarness.harness()
        let justInside = MovementReminderPolicy.offTrailMeters - 1

        observe(harness, offRouteMeters: justInside, after: 0)
        observe(harness, offRouteMeters: justInside, after: Self.dwell * 3)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    // MARK: Saying it once

    /// A hiker off the route for an hour has either noticed or chosen it. The
    /// opposite rule to a paused walk's, which repeats up to
    /// ``MovementReminderPolicy/maximumReminders`` times — and deliberately so.
    @Test("one departure is reported once, however long it lasts")
    func reportsADepartureOnce() async {
        let harness = MovementReminderHarness.harness()

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        for elapsed in stride(from: Self.dwell, through: Self.dwell * 20, by: Self.dwell) {
            observe(harness, offRouteMeters: Self.wellOff, after: elapsed)
        }
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.leftTheTrail])
    }

    /// Rejoining is the only thing that re-arms it, which is what makes a
    /// second wrong turn news again.
    @Test("rejoining the trail re-arms the reminder")
    func rejoiningReArmsTheReminder() async {
        let harness = MovementReminderHarness.harness()

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell)
        observe(harness, offRouteMeters: Self.onTheLine, after: Self.dwell * 2)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell * 3)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell * 4)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.leftTheTrail, .leftTheTrail])
    }

    /// A standing "Off the trail" is a claim about *now*. A hiker who has
    /// walked back onto the route should not find it on the Lock Screen.
    @Test("rejoining takes the banner back down")
    func rejoiningWithdrawsTheBanner() async {
        let harness = MovementReminderHarness.harness()

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell)
        observe(harness, offRouteMeters: Self.onTheLine, after: Self.dwell * 2)
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.leftTheTrail))
    }

    // MARK: What it refuses to conclude

    /// An unmatched fix is absence of evidence, not evidence of absence — a
    /// hiker on a path the route does not describe, or a fix the matcher
    /// could make nothing of. The tracker's own comment makes the same
    /// distinction about `recordOffRoute`.
    @Test("an unmatched fix leaves the watch exactly as it was")
    func anUnmatchedFixConcludesNothing() async {
        let harness = MovementReminderHarness.harness()

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        observe(harness, offRouteMeters: nil, after: Self.dwell)
        observe(harness, offRouteMeters: nil, after: Self.dwell * 2)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty, "nothing said the hiker was still off it")
    }

    /// The same precedence every other surface applies. A hiker recording
    /// their own track is not following somebody else's line, and two banners
    /// about one walk is the app arguing with itself in a pocket.
    @Test("a recording suppresses the off-trail reminder")
    func recordingOutranksTheOffTrailReminder() async {
        let harness = MovementReminderHarness.harness()
        // The closure rather than a paused recording, which is a different
        // thing: `recordingDidPause` arms the *pause* watch, and
        // `hasActiveRecording` is what the precedence rule actually asks.
        // The same setup `recordingOutranksTheWalk` uses.
        harness.controller.hasActiveRecording = { true }

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell)
        await harness.controller.settle()

        #expect(!harness.notifier.postedKinds.contains(.leftTheTrail))
    }

    /// It rides `movementRemindersEnabled` with the other three. A hiker who
    /// turned reminders off gets none of them.
    @Test("the hiker's switch governs it with the rest")
    func respectsTheSwitch() async {
        let harness = MovementReminderHarness.harness()
        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.controller.reconcileWithPreferences()

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// A walk that is over is not a trail anybody is on.
    @Test("ending the walk clears the watch and the banner")
    func endingTheWalkClearsIt() async {
        let harness = MovementReminderHarness.harness()
        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell)
        await harness.controller.settle()

        harness.controller.walkDidStopFollowing()
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell * 2)
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.leftTheTrail))
        #expect(
            harness.notifier.postedKinds == [.leftTheTrail],
            "a cleared watch starts a fresh departure rather than resuming one"
        )
    }

    // MARK: The banner itself

    /// The other three end in an instruction, because each has a button that
    /// carries it out. This one would be telling a hiker in fog what to do
    /// about terrain the app cannot see.
    @Test("the off-trail banner offers no button")
    func offersNoButton() {
        #expect(MovementReminderKind.leftTheTrail.action == nil)
        #expect(MovementReminderKind.resumeWalk.action == .resume)
    }
}
