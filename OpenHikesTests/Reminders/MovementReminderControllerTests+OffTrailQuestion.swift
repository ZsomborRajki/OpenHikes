//
//  MovementReminderControllerTests+OffTrailQuestion.swift
//  OpenHikesTests
//
//  The app's half of leaving the trail: when the walk session is told to ask
//  the hiker about it, and when it is told the question is over.
//
//  The banner and the question are one event, decided by one rule, and that
//  is what these hold: asked on the fix the banner is tried on, once per
//  departure, and again only after the hiker has been back on the trail. The
//  one place they part is permission. A banner needs iOS to let it through,
//  and the app's own screen does not.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementReminderControllerTests {
    /// What the controller told the walk session, in order: `true` to ask,
    /// `false` that the question is over.
    private final class Told {
        var events: [Bool] = []
    }

    private static let trail = "Ridge Loop"
    /// Comfortably past ``MovementReminderPolicy/offTrailMeters``.
    private static let wellOff = 400.0
    /// Inside ``MovementReminderPolicy/onTrailAgainMeters``.
    private static let onTheLine = 20.0
    private static let dwell = MovementReminderPolicy.offTrailDwell

    private func listening(to harness: MovementReminderHarness.Harness) -> Told {
        let told = Told()
        harness.controller.offTrailQuestionDidChange = { isAsked in told.events.append(isAsked) }
        return told
    }

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

    /// Off the trail from the first second, and still off it a dwell later.
    private func leaveTheTrail(_ harness: MovementReminderHarness.Harness, from seconds: TimeInterval = 0) {
        observe(harness, offRouteMeters: Self.wellOff, after: seconds)
        observe(harness, offRouteMeters: Self.wellOff, after: seconds + Self.dwell)
    }

    @Test("the hiker is asked on the fix the banner is posted for")
    func askedWithTheBanner() async {
        let harness = MovementReminderHarness.harness()
        let told = listening(to: harness)

        observe(harness, offRouteMeters: Self.wellOff, after: 0)
        #expect(told.events.isEmpty, "one fix off the line is as likely a bad fix as a wrong turn")
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell)
        await harness.controller.settle()

        #expect(told.events == [true])
        #expect(harness.notifier.postedKinds == [.leftTheTrail])
    }

    @Test("one departure asks once, however long it lasts")
    func asksOncePerDeparture() async {
        let harness = MovementReminderHarness.harness()
        let told = listening(to: harness)

        leaveTheTrail(harness)
        for elapsed in stride(from: Self.dwell * 2, through: Self.dwell * 20, by: Self.dwell) {
            observe(harness, offRouteMeters: Self.wellOff, after: elapsed)
        }
        await harness.controller.settle()

        #expect(told.events == [true])
    }

    @Test("back on the trail the question is over, and leaving it again asks again")
    func rejoiningEndsTheQuestionAndReArmsIt() async {
        let harness = MovementReminderHarness.harness()
        let told = listening(to: harness)

        leaveTheTrail(harness)
        await harness.controller.settle()
        observe(harness, offRouteMeters: Self.onTheLine, after: Self.dwell * 2)
        #expect(told.events == [true, false])

        leaveTheTrail(harness, from: Self.dwell * 3)
        await harness.controller.settle()

        #expect(told.events == [true, false, true])
        #expect(harness.notifier.postedKinds == [.leftTheTrail, .leftTheTrail], "as the banner is said again")
    }

    /// A banner needs iOS to let it through. A question on the app's own
    /// screen needs nobody's leave, and the refusal that holds the banner
    /// back for every later fix must not ask the question over again.
    @Test("a hiker who refused notifications is still asked, and still once")
    func askedWithoutPermission() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        let told = listening(to: harness)

        leaveTheTrail(harness)
        for elapsed in stride(from: Self.dwell * 2, through: Self.dwell * 6, by: Self.dwell) {
            observe(harness, offRouteMeters: Self.wellOff, after: elapsed)
        }
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
        #expect(told.events == [true])
    }

    /// A pause puts the banner's proposal away without ending the departure,
    /// and a refused banner is then proposed afresh on the first fix after
    /// the resume. The question was already asked about this departure.
    @Test("a pause and a resume off the trail do not ask about the same departure twice")
    func aPauseDoesNotReAsk() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        let told = listening(to: harness)
        leaveTheTrail(harness)

        harness.controller.walkDidPause(
            trailTitle: Self.trail,
            atDistance: 500,
            on: start.addingTimeInterval(Self.dwell * 2)
        )
        harness.controller.walkDidResumeOrEnd()
        observe(harness, offRouteMeters: Self.wellOff, after: Self.dwell * 3)
        await harness.controller.settle()

        #expect(told.events == [true])
    }

    @Test("a walk that stopped following starts the next one's departures afresh")
    func stoppingFollowingReArmsTheQuestion() async {
        let harness = MovementReminderHarness.harness()
        let told = listening(to: harness)
        leaveTheTrail(harness)

        harness.controller.walkDidStopFollowing()
        leaveTheTrail(harness, from: Self.dwell * 2)
        await harness.controller.settle()

        #expect(told.events == [true, true])
    }

    @Test("with reminders off nobody is asked, and turning them off takes a standing question back")
    func theSwitchGovernsTheQuestion() async {
        let quiet = MovementReminderHarness.harness(remindersEnabled: false)
        let unasked = listening(to: quiet)
        leaveTheTrail(quiet)
        #expect(unasked.events.isEmpty)

        let harness = MovementReminderHarness.harness()
        let told = listening(to: harness)
        leaveTheTrail(harness)
        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.controller.reconcileWithPreferences()
        await harness.controller.settle()

        #expect(told.events.first == true)
        #expect(told.events.last == false)
    }

    @Test("a recording is never asked about a trail it is not following")
    func aRecordingIsNotAsked() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.hasActiveRecording = { true }
        let told = listening(to: harness)

        leaveTheTrail(harness)
        await harness.controller.settle()

        #expect(told.events.isEmpty)
    }
}
