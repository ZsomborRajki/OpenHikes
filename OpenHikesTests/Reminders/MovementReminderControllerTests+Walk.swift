//
//  MovementReminderControllerTests+Walk.swift
//  OpenHikesTests
//
//  The controller's half of a paused walk: which subject the reminder belongs
//  to when a recording is running too, which direction along the route counts
//  as movement, and — the whole of what a walk's evidence is worth — which
//  fixes are about the pause at all.
//
//  A walk is watched by feeds it does not own, so its fixes arrive out of
//  order and some of them predate the Pause they are offered against. Neither
//  is a walker who has set off again.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementReminderControllerTests {
    @Test("covering the trail with the walk paused posts the walk reminder")
    func walkingWhilePausedPostsTheReminder() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 1200, on: start)

        harness.controller.walkObserved(distanceAlongRoute: 1400, at: start)
        harness.controller.walkObserved(
            distanceAlongRoute: 1900,
            at: start.addingTimeInterval(1800)
        )
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeWalk])
        #expect(harness.notifier.posted.first?.body.contains("Ridge Loop") == true)
    }

    /// The same precedence the widget and the Lock Screen apply. A walker
    /// recording their own track along an imported route has one walk, and
    /// the recording is the half that would be lost.
    @Test("a recording suppresses the walk's reminder")
    func recordingOutranksTheWalk() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.hasActiveRecording = { true }
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 0, on: start)

        harness.controller.walkObserved(distanceAlongRoute: 2000, at: start)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// Backwards along the route is movement too — a walker who turned round
    /// at the summit with the walk paused is covering ground either way.
    @Test("the walk's displacement is measured in both directions")
    func walkingBackDownAlsoReminds() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 2000, on: start)

        harness.controller.walkObserved(distanceAlongRoute: 1400, at: start)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeWalk])
    }

    @Test("resuming or ending the walk withdraws its reminder")
    func walkResumeWithdraws() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 0, on: start)

        harness.controller.walkDidResumeOrEnd()
        harness.controller.walkObserved(distanceAlongRoute: 3000, at: start)
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.resumeWalk))
        #expect(harness.notifier.posted.isEmpty)
    }

    /// The walk's half of the rule the recording learned in #189, and the
    /// case the watch cannot catch on its own: a fresh watch has no earlier
    /// reading to reject the first one against, so the pause is the only
    /// thing that says this fix is about the walk that led up to it.
    @Test("a fix taken before the walk was paused is not evidence about the pause")
    func prePauseWalkFixIsDropped() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(
            trailTitle: "Ridge Loop",
            atDistance: 1200,
            on: start.addingTimeInterval(600)
        )

        // A kilometre away, and taken while the walker was still walking it.
        harness.controller.walkObserved(distanceAlongRoute: 200, at: start)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// Fixes reach a paused walk from two feeds, and the background one
    /// matches behind an await — so they arrive out of order. An older
    /// reading says where the walker was, and the watch has already been told
    /// where they were later than that.
    @Test("a walk reading older than one already taken is dropped")
    func outOfOrderWalkFixIsDropped() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 1200, on: start)

        harness.controller.walkObserved(
            distanceAlongRoute: 1250,
            at: start.addingTimeInterval(600)
        )
        harness.controller.walkObserved(
            distanceAlongRoute: 2000,
            at: start.addingTimeInterval(300)
        )
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// And the guards above are a boundary, not a mute: a walker who really
    /// does set off again after pausing still hears about it.
    @Test("movement after the pause still reminds")
    func postPauseWalkFixStillReminds() async {
        let harness = MovementReminderHarness.harness()
        let pausedAt = start.addingTimeInterval(600)
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 1200, on: pausedAt)

        harness.controller.walkObserved(distanceAlongRoute: 200, at: start)
        harness.controller.walkObserved(
            distanceAlongRoute: 2000,
            at: pausedAt.addingTimeInterval(300)
        )
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeWalk])
    }
}
