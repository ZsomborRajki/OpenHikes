//
//  MovementReminderControllerTests+Dusk.swift
//  OpenHikesTests
//
//  The after-dark reminder, through the controller: the switch, the
//  recording's precedence, once per walk, and what re-arms it.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementReminderControllerTests {
    private static let duskTrail = "Ridge Loop"
    private static var dusk: Date { MovementReminderHarness.start.addingTimeInterval(2 * 3600) }

    private func estimate(_ harness: MovementReminderHarness.Harness, finishingAfterDusk minutes: Double) {
        harness.controller.walkFinishEstimated(
            finishAt: Self.dusk.addingTimeInterval(minutes * 60),
            civilDusk: Self.dusk,
            trailTitle: Self.duskTrail,
            at: MovementReminderHarness.start
        )
    }

    @Test("a walk that ends after dusk is told so, naming the trail, once")
    func afterDarkIsPostedOnce() async {
        let harness = MovementReminderHarness.harness()

        estimate(harness, finishingAfterDusk: 20)
        estimate(harness, finishingAfterDusk: 25)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.afterDark])
        #expect(harness.notifier.posted.first?.body.contains(Self.duskTrail) == true)
    }

    @Test("the hiker's switch silences it")
    func afterDarkRespectsTheSwitch() async {
        let harness = MovementReminderHarness.harness(remindersEnabled: false)
        estimate(harness, finishingAfterDusk: 20)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)
    }

    /// A recording has no route to measure "left" against, and outranks a
    /// followed trail on every surface.
    @Test("a recording in progress silences it")
    func aRecordingOutranksIt() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.hasActiveRecording = { true }
        estimate(harness, finishingAfterDusk: 20)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("ending the walk takes it down and lets the next walk be told")
    func stoppingRearmsAndWithdraws() async {
        let harness = MovementReminderHarness.harness()
        estimate(harness, finishingAfterDusk: 20)
        harness.controller.walkDidStopFollowing()
        estimate(harness, finishingAfterDusk: 20)
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.afterDark))
        #expect(harness.notifier.postedKinds == [.afterDark, .afterDark])
    }
}
