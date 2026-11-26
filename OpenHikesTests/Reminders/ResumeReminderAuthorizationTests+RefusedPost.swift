//
//  ResumeReminderAuthorizationTests+RefusedPost.swift
//  OpenHikesTests
//
//  A Resume reminder the notification centre refuses after permission was
//  given (#1682). The pause spends its reminder before the post, which keeps
//  overlapping attempts to one banner, so a refusal gives it back: the pause
//  is left as a refused permission leaves it, with the reminder still owed
//  and all of its allowance. What the hiker did while the banner was out
//  still counts, and a refusal that lands after the pause was replaced
//  leaves the new one alone.
//

import Foundation
@testable import OpenHikes
import Testing

extension ResumeReminderAuthorizationTests {
    private typealias Harness = MovementReminderHarness.Harness

    /// Just past the quiet period, so every step below is a fresh attempt.
    private var refusalGap: TimeInterval { MovementReminderPolicy.quietFor + 1 }
    /// Past the distance rule, so every step below is new ground as well.
    private var refusalLeg: Double { MovementReminderPolicy.awayMeters + 100 }

    @Test("a refused Resume reminder leaves the pause all its reminders", arguments: Subject.allCases)
    func aRefusedPostSpendsNothing(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        pause(subject, in: harness)
        await harness.controller.settle()
        harness.notifier.refusesPosts = 1

        await step(subject, meters: refusalLeg, after: refusalGap, in: harness)
        #expect(harness.notifier.refusedPosts == 1)
        #expect(harness.notifier.posted.isEmpty)

        for step in 2...5 {
            await self.step(subject, meters: refusalLeg * Double(step), after: refusalGap * Double(step), in: harness)
        }
        #expect(harness.notifier.postedKinds == allReminders(subject), "the cap counts what reached the hiker")
    }

    /// Owed as a reminder held back by a refused permission is owed, so the
    /// way back into the app says it without waiting out the quiet period.
    @Test("a refused Resume reminder is still owed on the way back to the app", arguments: Subject.allCases)
    func aRefusedPostIsStillOwed(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        pause(subject, in: harness)
        await harness.controller.settle()
        harness.notifier.refusesPosts = 1
        await step(subject, meters: refusalLeg, after: refusalGap, in: harness)

        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [subject.kind])
    }

    /// The hiker went back to where they paused while the refused banner was
    /// on its way. Nothing is owed, and nothing was spent, so a departure
    /// that holds is still told.
    @Test("a hiker who walked back while a refused banner was out is owed nothing", arguments: Subject.allCases)
    func walkingBackDuringARefusedPost(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        pause(subject, in: harness)
        await harness.controller.settle()
        harness.notifier.holdsThePost = true
        observeStep(subject, meters: refusalLeg, after: refusalGap, in: harness)
        guard await harness.notifier.awaitPost() else { return }

        observeStep(subject, meters: 50, after: refusalGap + 60, in: harness)
        harness.notifier.answerPost(taken: false)
        await harness.controller.settle()
        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        await step(subject, meters: refusalLeg, after: refusalGap * 2, in: harness)
        #expect(harness.notifier.postedKinds == [subject.kind])
    }

    /// And one who walked on is told how far they have come by now.
    @Test("a hiker who walked on while a refused banner was out is told how far", arguments: Subject.allCases)
    func walkingOnDuringARefusedPost(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        pause(subject, in: harness)
        await harness.controller.settle()
        harness.notifier.holdsThePost = true
        observeStep(subject, meters: refusalLeg, after: refusalGap, in: harness)
        guard await harness.notifier.awaitPost() else { return }

        observeStep(subject, meters: 2000, after: refusalGap + 60, in: harness)
        harness.notifier.answerPost(taken: false)
        await harness.controller.settle()
        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [subject.kind])
        let body = harness.notifier.posted.first?.body ?? ""
        #expect(body.contains(MovementReminderWording.distance(2000)), "\(body)")
    }

    /// The refusal arrives after the hiker resumed and paused again. It was
    /// the old pause's reminder, and the new pause keeps all of its own.
    @Test("a refusal that lands after the pause was replaced leaves the new pause alone", arguments: Subject.allCases)
    func aLateRefusalLeavesTheNewPause(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        pause(subject, in: harness)
        await harness.controller.settle()
        harness.notifier.holdsThePost = true
        observeStep(subject, meters: refusalLeg, after: refusalGap, in: harness)
        guard await harness.notifier.awaitPost() else { return }

        resume(subject, in: harness)
        let repausedAfter = refusalGap * 2
        pause(subject, in: harness, after: repausedAfter)
        harness.notifier.answerPost(taken: false)
        await harness.controller.settle()
        #expect(harness.notifier.refusedPosts == 1)

        for step in 1...4 {
            let seconds = repausedAfter + refusalGap * Double(step)
            await self.step(subject, meters: refusalLeg * Double(step), after: seconds, in: harness)
        }
        #expect(harness.notifier.postedKinds == allReminders(subject))
    }

    // MARK: Helpers

    /// Every reminder one pause may say.
    private func allReminders(_ subject: Subject) -> [MovementReminderKind] {
        Array(repeating: subject.kind, count: MovementReminderPolicy.maximumReminders)
    }

    private func step(
        _ subject: Subject,
        meters: Double,
        after seconds: TimeInterval,
        in harness: Harness
    ) async {
        observeStep(subject, meters: meters, after: seconds, in: harness)
        await harness.controller.settle()
    }

    private func observeStep(
        _ subject: Subject,
        meters: Double,
        after seconds: TimeInterval,
        in harness: Harness
    ) {
        let taken = start.addingTimeInterval(seconds)
        switch subject {
        case .walk:
            harness.controller.walkObserved(distanceAlongRoute: meters, at: taken)
        case .recording:
            harness.controller.recordingObserved(
                MovementReminderHarness.fix(northOfAnchorBy: meters, takenAt: taken)
            )
        }
    }
}
