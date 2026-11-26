//
//  LongAutoPauseReminderTests.swift
//  OpenHikesTests
//
//  The banner a long auto-pause is owed (#1470): a recording Auto-Pause has
//  held paused for half an hour may have outlived its hike, and is still
//  spending location. Posted when the pause begins and shown when the half
//  hour is up, because the phone it is for — on a table at home — delivers
//  no fix to decide anything by. Taken back down by whatever ends the pause.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing
import UserNotifications

@MainActor
@Suite("Long auto-pause reminder")
struct LongAutoPauseReminderTests {
    let start = MovementReminderHarness.start
    /// When the stop began: Auto-Pause calls one five minutes into it, and
    /// counts it from its start.
    var stoppedAt: Date { start.addingTimeInterval(-5 * 60) }

    @Test("an auto-pause posts a banner to be shown half an hour after the stop began")
    func postsAheadOfItsMoment() async throws {
        let harness = MovementReminderHarness.harness()

        harness.controller.recordingDidAutoPause(since: stoppedAt)
        await harness.controller.settle()

        let reminder = try #require(harness.notifier.posted.last)
        let delay = try #require(reminder.delay)
        #expect(reminder.kind == .longAutoPause)
        #expect(delay.isApproximatelyEqual(to: 25 * 60, absoluteTolerance: 0.001))
        #expect(reminder.title == MovementReminderWording.longAutoPause(pausedFor: 30 * 60).title)
        #expect(reminder.body == MovementReminderWording.longAutoPause(pausedFor: 30 * 60).body)
    }

    /// Stop can end in a review of the matched line, which a banner cannot
    /// show, so the banner opens the app and offers nothing of its own.
    @Test("the banner offers no button, and waits for a Focus")
    func noButton() {
        #expect(MovementReminderKind.longAutoPause.action == nil)
        #expect(MovementReminderKind.longAutoPause.interruptionLevel == .active)
    }

    @Test("walking on from the auto-pause takes the banner back down")
    func walkingOnWithdraws() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidAutoPause(since: stoppedAt)
        await harness.controller.settle()

        harness.controller.recordingAutoPauseDidEnd()
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.last == .longAutoPause)
    }

    /// A pause by hand, Resume and Stop each answer the question, whichever
    /// way the hiker took.
    @Test("a pause, a resume or the end of the recording takes the banner down", arguments: [0, 1, 2])
    func everyEndWithdraws(way: Int) async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidAutoPause(since: stoppedAt)
        await harness.controller.settle()
        let before = harness.notifier.withdrawn.count

        switch way {
        case 0: harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)
        case 1: harness.controller.recordingDidResume()
        default: harness.controller.recordingDidEnd()
        }
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.dropFirst(before).contains(.longAutoPause))
    }

    @Test("with Hike Reminders off nothing is posted")
    func switchOff() async {
        let harness = MovementReminderHarness.harness(remindersEnabled: false)

        harness.controller.recordingDidAutoPause(since: stoppedAt)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.notifier.authorizationRequests == 0)
    }

    /// The hiker walked on while the permission prompt was up: the answer
    /// arrives for a pause that is over.
    @Test("an auto-pause that ended while permission was asked posts nothing")
    func endedDuringThePrompt() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true

        harness.controller.recordingDidAutoPause(since: stoppedAt)
        #expect(await harness.notifier.awaitPrompt())
        harness.controller.recordingAutoPauseDidEnd()
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(!harness.notifier.postedKinds.contains(.longAutoPause))
    }

    /// The owner's call in #1682 was left to this change: the stop is the one
    /// moment the banner can be scheduled from, so one the system refuses is
    /// not posted again, not even on the way back into the app. The next
    /// stop still has its own.
    @Test("a banner the system refuses is not posted again, and the next stop has its own")
    func aRefusedBannerIsNotRetried() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.refusesPosts = 1
        harness.controller.recordingDidAutoPause(since: stoppedAt)
        await harness.controller.settle()

        harness.postDidBecomeActive()
        await harness.controller.settle()
        #expect(harness.notifier.refusedPosts == 1)
        #expect(harness.notifier.posted.isEmpty)

        harness.controller.recordingAutoPauseDidEnd()
        harness.controller.recordingDidAutoPause(since: start)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.longAutoPause])
    }

    /// Answered so late that the half hour has already passed: the banner is
    /// shown at once rather than not at all.
    @Test("an overdue banner is shown at once")
    func overdue() async throws {
        let harness = MovementReminderHarness.harness()
        harness.clock.advance(by: 40 * 60)

        harness.controller.recordingDidAutoPause(since: stoppedAt)
        await harness.controller.settle()

        let reminder = try #require(harness.notifier.posted.last)
        #expect(reminder.delay.map { $0 <= 0 } == true)
        #expect(SystemMovementReminderNotifier.trigger(after: reminder.delay) == nil)
    }

    @Test("the system is asked to show a banner after its delay, and the others at once")
    func systemTrigger() throws {
        let trigger = try #require(SystemMovementReminderNotifier.trigger(after: 1500))

        #expect(trigger.timeInterval == 1500)
        #expect(!trigger.repeats)
        #expect(SystemMovementReminderNotifier.trigger(after: nil) == nil)
    }
}
