//
//  ResumeReminderAuthorizationTests.swift
//  OpenHikesTests
//
//  A Resume reminder is earned by one pause and posted after a permission
//  answer, and that answer takes as long as the hiker takes to read the
//  prompt. By then the pause can be over, replaced, silenced or outranked, and
//  a banner asking them to resume something already running is the app
//  disagreeing with itself about a walk it can see the state of.
//
//  ``MovementWarningAuthorizationTests`` asks the same question of the
//  once-only warnings, which belong to a condition rather than to a pause.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Resume reminders across notification authorization")
struct ResumeReminderAuthorizationTests {
    private final class RecordingState {
        var isActive = false
    }

    nonisolated enum Subject: CaseIterable, Sendable {
        case recording, walk

        var kind: MovementReminderKind {
            switch self {
            case .recording: .resumeRecording
            case .walk: .resumeWalk
            }
        }
    }

    private let start = MovementReminderHarness.start

    /// The boundary rather than a mute: everything below stops a post, and
    /// each would pass against a controller that never posted at all.
    @Test("a pause that is still current posts once permission arrives", arguments: Subject.allCases)
    func aCurrentPausePosts(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        guard await holdEarnedReminder(subject, in: harness) else { return }

        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [subject.kind])
    }

    @Test("resuming cancels a reminder awaiting permission", arguments: Subject.allCases)
    func resumingCancelsTheReminder(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        guard await holdEarnedReminder(subject, in: harness) else { return }

        resume(subject, in: harness)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.notifier.withdrawn.last == subject.kind)
    }

    /// `walkDidResumeOrEnd()` is the walk's half of this, which is the case
    /// above: ending a walk and resuming one are the same call.
    @Test("ending the recording cancels a reminder awaiting permission")
    func endingTheRecordingCancelsTheReminder() async {
        let harness = MovementReminderHarness.harness()
        guard await holdEarnedReminder(.recording, in: harness) else { return }

        harness.controller.recordingDidEnd()
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// "Is something paused" is not the question, *this* pause is. The new one
    /// has moved nowhere yet, and the old one's reminder would say it had.
    @Test("a replacement pause inherits no reminder and earns its own", arguments: Subject.allCases)
    func aReplacementPauseEarnsItsOwnReminder(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        guard await holdEarnedReminder(subject, in: harness) else { return }

        resume(subject, in: harness)
        pause(subject, in: harness, after: 1800, trailTitle: "New Walk")
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        earn(subject, in: harness, after: 1860)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [subject.kind])
        if subject == .walk {
            #expect(harness.notifier.posted.first?.body.contains("New Walk") == true)
        }
    }

    @Test("turning reminders off cancels a reminder awaiting permission", arguments: Subject.allCases)
    func turningRemindersOffCancelsTheReminder(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        guard await holdEarnedReminder(subject, in: harness) else { return }

        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.notifier.withdrawn.contains(subject.kind))
    }

    /// The observer is scoped to the controller's own `UserDefaults` object,
    /// so a write through another instance of the suite is a switch that has
    /// moved with nobody told yet: the pause is still armed, and only reading
    /// the switch again can stop the post.
    @Test("the switch is read after the answer, ahead of its observer", arguments: Subject.allCases)
    func theSwitchIsReadAfterTheAnswer(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        guard await holdEarnedReminder(subject, in: harness) else { return }

        UserDefaults(suiteName: harness.suiteName)?
            .set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("a recording taking over silences a walk reminder awaiting permission")
    func aRecordingTakingOverSilencesTheWalk() async {
        let harness = MovementReminderHarness.harness()
        let recording = RecordingState()
        harness.controller.hasActiveRecording = { recording.isActive }
        guard await holdEarnedReminder(.walk, in: harness) else { return }

        recording.isActive = true
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// A paused recording is an active one, so the precedence above must stay
    /// the walk's alone or the recording would silence its own reminder.
    @Test("a recording does not outrank its own reminder")
    func aRecordingDoesNotSilenceItself() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.hasActiveRecording = { true }
        guard await holdEarnedReminder(.recording, in: harness) else { return }

        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeRecording])
    }

    /// Queued behind the pause's own prompt rather than waiting on one of its
    /// own. A second prompt here would be a question about a finished pause.
    @Test("a reminder queued behind a prompt asks nothing once its pause is over", arguments: Subject.allCases)
    func aQueuedReminderForAnEndedPauseAsksNothing(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        pause(subject, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }
        earn(subject, in: harness)
        resume(subject, in: harness)

        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.authorizationRequests == 1)
        #expect(harness.notifier.posted.isEmpty)
    }

    /// Pauses, lets that pause's own prompt go by, then earns a reminder and
    /// leaves *its* prompt on screen.
    ///
    /// - Returns: whether the prompt arrived; a `false` is already a failure.
    private func holdEarnedReminder(
        _ subject: Subject,
        in harness: MovementReminderHarness.Harness
    ) async -> Bool {
        pause(subject, in: harness)
        await harness.controller.settle()
        harness.notifier.holdsThePrompt = true
        earn(subject, in: harness)
        return await harness.notifier.awaitPrompt()
    }

    private func pause(
        _ subject: Subject,
        in harness: MovementReminderHarness.Harness,
        after seconds: TimeInterval = 0,
        trailTitle: String = "Ridge Loop"
    ) {
        let pausedAt = start.addingTimeInterval(seconds)
        switch subject {
        case .recording:
            harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: pausedAt)
        case .walk:
            harness.controller.walkDidPause(trailTitle: trailTitle, atDistance: 0, on: pausedAt)
        }
    }

    /// Far enough from the anchor to earn a reminder from a fresh watch.
    private func earn(
        _ subject: Subject,
        in harness: MovementReminderHarness.Harness,
        after seconds: TimeInterval = 60
    ) {
        let now = start.addingTimeInterval(seconds)
        let moved = MovementReminderPolicy.awayMeters + 100
        switch subject {
        case .recording:
            harness.controller.recordingObserved(
                MovementReminderHarness.fix(northOfAnchorBy: moved, takenAt: now),
                at: now
            )
        case .walk:
            harness.controller.walkObserved(distanceAlongRoute: moved, at: now)
        }
    }

    private func resume(_ subject: Subject, in harness: MovementReminderHarness.Harness) {
        switch subject {
        case .recording: harness.controller.recordingDidResume()
        case .walk: harness.controller.walkDidResumeOrEnd()
        }
    }
}
