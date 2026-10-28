//
//  MovementWarningAuthorizationTests+Conditions.swift
//  OpenHikesTests
//
//  A permission answer is about delivery, not evidence that the condition
//  which asked for it still holds. These change the facts while it waits.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementWarningAuthorizationTests {
    @Test("a mature departure stays pending through the hysteresis band", arguments: [false, true])
    func aPendingDepartureSurvivesTheHysteresisBand(holdingPrompt: Bool) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = holdingPrompt
        harness.notifier.isAuthorized = holdingPrompt
        makeEligible(.offTrail, in: harness)
        if holdingPrompt {
            guard await harness.notifier.awaitPrompt() else { return }
        } else {
            await harness.controller.settle()
        }

        let band = (MovementReminderPolicy.onTrailAgainMeters + MovementReminderPolicy.offTrailMeters) / 2
        harness.controller.walkObserved(
            offRouteMeters: band,
            trailTitle: "Ridge Loop",
            at: MovementReminderHarness.start.addingTimeInterval(MovementReminderPolicy.offTrailDwell + 60)
        )
        if holdingPrompt {
            harness.notifier.answerPrompt(allowing: true)
        } else {
            harness.notifier.isAuthorized = true
            harness.postDidBecomeActive()
        }
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.leftTheTrail])
        makeEligible(.offTrail, in: harness, after: 3600)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.leftTheTrail], "the departure is still reported only once")
    }

    @Test("dusk passing while the prompt is up makes the warning obsolete")
    func duskPassingCancelsThePendingWarning() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(.dusk, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        harness.clock.advance(by: 2 * 3600)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("the warning uses the latest eligible reading", arguments: [Warning.offTrail, .dusk])
    func theLatestReadingSuppliesTheWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        makeEligible(warning, in: harness, after: 3600, trailTitle: "Renamed Ridge")
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [warning.kind])
        #expect(harness.notifier.posted.first?.body.contains("Renamed Ridge") == true)
    }

    @Test("a replacement condition has its own allowance", arguments: Warning.allCases)
    func aNewConditionReplacesTheOldProposal(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        clearCondition(warning, in: harness)
        makeEligible(warning, in: harness, after: 3600, trailTitle: "New Departure")
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [warning.kind])
        if warning != .stillness {
            #expect(harness.notifier.posted.first?.body.contains("New Departure") == true)
        }
    }

    @Test("pausing the walk cancels an undelivered walk warning", arguments: [Warning.offTrail, .dusk])
    func pausingTheWalkCancelsThePendingWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 0, on: MovementReminderHarness.start)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
        harness.controller.walkDidResumeOrEnd()
        makeEligible(warning, in: harness)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    @Test("pausing the recording cancels an undelivered pause suggestion")
    func pausingTheRecordingCancelsThePendingSuggestion() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(.stillness, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: MovementReminderHarness.start)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("an estimate with no dusk cancels the pending dusk warning")
    func losingDuskCancelsThePendingWarning() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(.dusk, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        harness.controller.walkFinishEstimated(
            finishAt: MovementReminderHarness.start.addingTimeInterval(3 * 3600),
            civilDusk: nil,
            trailTitle: "Ridge Loop",
            at: MovementReminderHarness.start
        )
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }
}
