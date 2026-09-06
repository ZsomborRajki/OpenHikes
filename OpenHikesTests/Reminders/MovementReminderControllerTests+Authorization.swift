//
//  MovementReminderControllerTests+Authorization.swift
//  OpenHikesTests
//
//  The switch the walker never sees in this app: iOS's own permission.
//
//  ``MovementReminderControllerTests`` covers what the controller decides when
//  a reminder *can* be delivered. These cover what it gives back when one
//  cannot — which for a paused recording is not a nicety but the location feed
//  the recorder is holding open on its behalf, complete with a background
//  activity session and the location indicator, for a banner the system will
//  never show.
//
//  The awkward half is time. The answer comes from a prompt the walker reads
//  at their own pace, so it can land after they have tapped Resume, or after
//  they have resumed, walked on and paused again — and a refusal applied to
//  the wrong one of those would park the sensors of a running recording. Every
//  test here that holds the prompt is about that.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementReminderControllerTests {
    /// The switch is not the only thing that can silence a reminder, and the
    /// other one costs the walker battery until it is heard: a paused
    /// recording is watched by a location feed the recorder keeps alive, and
    /// under a refusal there is nothing for that feed to produce.
    @Test("a refused permission gives the recording's watch back")
    func refusedPermissionEndsTheWatch() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        var endedWatches = 0
        harness.controller.watchingDidEnd = { endedWatches += 1 }

        #expect(harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start))
        await harness.controller.settle()

        #expect(endedWatches == 1, "the recorder is the only thing that can stop the feed")
        #expect(
            !harness.controller.isWatchingPausedRecording,
            "and the anchor goes with it, so a fix that arrives anyway measures nothing"
        )
    }

    /// The walker left the prompt on screen and tapped Resume before reading
    /// it. Acting on the answer now would park the sensors of a recording
    /// that is running — the walk would stop being recorded because of a
    /// question about a pause that is over.
    @Test("a refusal that lands after Resume ends no watch")
    func lateRefusalAfterResumeEndsNoWatch() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        var endedWatches = 0
        harness.controller.watchingDidEnd = { endedWatches += 1 }
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)
        await harness.notifier.awaitPrompt()
        harness.controller.recordingDidResume()

        harness.notifier.answerPrompt(allowing: false)
        await harness.controller.settle()

        #expect(endedWatches == 0)
    }

    /// The same late answer, arriving at a walker who resumed, walked on and
    /// paused again. "Is a recording paused" is not the question — *this*
    /// pause is — and the second one was never refused.
    @Test("a refusal does not take the next pause's watch")
    func lateRefusalLeavesALaterPauseWatched() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        var endedWatches = 0
        harness.controller.watchingDidEnd = { endedWatches += 1 }
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)
        await harness.notifier.awaitPrompt()
        harness.controller.recordingDidResume()
        harness.controller.recordingDidPause(
            at: MovementReminderHarness.anchor,
            on: start.addingTimeInterval(1800)
        )

        harness.notifier.answerPrompt(allowing: false)
        await harness.controller.settle()

        #expect(endedWatches == 0)
        #expect(harness.controller.isWatchingPausedRecording)
    }

    /// Permission is not a default and taking it away means leaving for iOS
    /// Settings, so a pause that was watched when the walker left can be
    /// unwatchable by the time they come back. Driven through the reconcile
    /// call rather than by posting `UIApplication.didBecomeActiveNotification`
    /// — see the note on ``MovementReminderController/reconcileWithAuthorization(prompting:)``.
    @Test("permission revoked during a pause stops the watch on the way back")
    func revokedPermissionEndsTheWatchOnReturn() async {
        let harness = MovementReminderHarness.harness()
        var endedWatches = 0
        harness.controller.watchingDidEnd = { endedWatches += 1 }
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)
        await harness.controller.settle()
        #expect(endedWatches == 0, "precondition: the pause was allowed its watch")

        harness.notifier.isAuthorized = false
        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()

        #expect(endedWatches == 1)
        #expect(
            harness.notifier.authorizationRequests == 1,
            "coming back to the app is not a moment to ask the walker anything"
        )
        #expect(harness.notifier.silentChecks == 1)
    }

    /// The other half of that: a return to the foreground with nothing paused
    /// runs on every app activation, and must not become a cross-process call
    /// per activation.
    @Test("returning to the foreground with nothing watched asks nothing")
    func foregroundWithNothingWatchedAsksNothing() async {
        let harness = MovementReminderHarness.harness()

        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()

        #expect(harness.notifier.silentChecks == 0)
        #expect(harness.notifier.authorizationRequests == 0)
    }
}
