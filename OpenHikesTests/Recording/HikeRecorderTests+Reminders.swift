//
//  HikeRecorderTests+Reminders.swift
//  OpenHikesTests
//
//  That a pause reaches the reminders, and that it costs nothing when it must
//  not.
//
//  ``MovementReminderControllerTests`` pins what the controller decides; these
//  pin that the recorder asks it, at the two moments where the answer changes
//  what the GPS is doing. The failure they exist to catch is the quiet one:
//  the policy keeps returning the right answer, the controller keeps holding
//  the right anchor, and no fix ever arrives to measure against it because the
//  pause tore the feed down anyway.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

extension HikeRecorderTests {
    /// Where the recording starts, and a point about six hundred metres north
    /// of it — far enough to cross ``MovementReminderPolicy/awayMeters`` and
    /// close enough that nothing else in the recorder treats it as a jump.
    private static let trailheadLatitude = 47.63
    private static let downTheValleyLatitude = 47.6354

    /// A recorder recording, with a reminder controller behind it.
    private func recordingRecorder(
        _ harness: MovementReminderHarness.Harness
    ) async -> HikeRecorder {
        let hikeRecorder = makeRecorder(movementReminders: harness.controller)
        await hikeRecorder.start()
        source.deliver(fix(latitude: Self.trailheadLatitude))
        return hikeRecorder
    }

    @Test("a pause keeps a watch alive rather than stopping the feed")
    func pauseWatchesForMovement() async {
        let harness = MovementReminderHarness.harness()
        let hikeRecorder = await recordingRecorder(harness)
        let stopsBefore = source.stopCount

        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()

        #expect(source.movementWatchStarts == 1)
        #expect(
            source.stopCount == stopsBefore,
            "the feed is swapped, not torn down — see startMovementWatch()"
        )
    }

    /// The other half of the same decision, and the one that keeps this
    /// feature free for a hiker who does not want it.
    @Test("a pause with reminders off stops everything, as it always did")
    func pauseWithoutRemindersStopsTheFeed() async {
        let harness = MovementReminderHarness.harness(remindersEnabled: false)
        let hikeRecorder = await recordingRecorder(harness)

        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()

        #expect(source.movementWatchStarts == 0)
        #expect(source.stopCount == 1)
    }

    /// The issue's own case: the hiker left the restaurant without tapping
    /// Resume, and half a kilometre later the phone says so.
    @Test("a fix that arrives while paused can post the resume reminder")
    func aPausedRecorderRemindsOnMovement() async {
        let harness = MovementReminderHarness.harness()
        let hikeRecorder = await recordingRecorder(harness)
        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()

        clock.advance(by: 1800)
        source.deliver(fix(latitude: Self.downTheValleyLatitude, accuracy: 30))
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeRecording])
        #expect(
            hikeRecorder.stats.pointCount == 1,
            "a watch fix is evidence the hiker moved, never part of the track"
        )
    }

    /// The pause a hiker most often forgets is one their phone died during:
    /// the journal comes back at the next launch, the recording is parked, and
    /// nothing in the new process is holding the anchor the previous one had.
    @Test("a pause recovered from the journal is watched again")
    func recoveredPauseIsRearmed() async throws {
        let harness = MovementReminderHarness.harness()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: UUID(), startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: Self.trailheadLatitude,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.pause(at: clock.now)
        try await journal.close()
        let hikeRecorder = makeRecorder(movementReminders: harness.controller)

        await hikeRecorder.recoverOpenSession()
        clock.advance(by: 1800)
        source.deliver(fix(latitude: Self.downTheValleyLatitude, accuracy: 30))
        await harness.controller.settle()

        #expect(hikeRecorder.phase == .paused)
        #expect(source.movementWatchStarts == 1)
        #expect(harness.notifier.postedKinds == [.resumeRecording])
    }

    /// The switch is read at every decision, which stops the *reminders* —
    /// but a pause has already told this recorder to keep a feed alive, and
    /// with When In Use authorization that feed holds a background activity
    /// session and the location indicator for the rest of the pause.
    @Test("turning reminders off mid-pause stops the feed the pause started")
    func disablingRemindersMidPauseStopsTheFeed() async {
        let harness = MovementReminderHarness.harness()
        let hikeRecorder = await recordingRecorder(harness)
        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()
        #expect(source.movementWatchStarts == 1, "precondition: the pause is being watched")
        let stopsBefore = source.stopCount

        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        await harness.controller.settle()

        #expect(
            source.stopCount == stopsBefore + 1,
            "the coarse feed a pause started has to go with the switch"
        )
    }

    /// The hiker's switch is only half of "reminders are on". The other half
    /// is iOS's, and a hiker who has denied notifications — months ago, or at
    /// the prompt this pause puts up — cannot be sent anything, so a pause
    /// that keeps a feed alive for a banner is spending a background activity
    /// session and the location indicator on nothing at all.
    @Test("a pause the hiker cannot be notified about stops the feed")
    func pauseWithNotificationsDeniedStopsTheFeed() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        let hikeRecorder = await recordingRecorder(harness)

        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()
        await harness.controller.settle()

        #expect(
            source.stopCount == 1,
            "a refusal costs the hiker what the switch costs them: nothing"
        )
    }

    /// The other order of the same race, and the one the recorder decides.
    /// The refusal is answered while the pause is still being written, so the
    /// boolean the pause computed is stale by the time the sensors are parked
    /// — which is why they ask the controller again instead.
    ///
    /// The interleaving is held open rather than hoped for. `pause()` starts
    /// the notification work and the journal work on two queues that do not
    /// wait for each other, so awaiting the settle before the drain orders
    /// only this test's own waits: with the write landing first the recorder
    /// is still correct — it starts a watch and the refusal stops it — but it
    /// is no longer the branch this test is named after. Gating the queue is
    /// what makes the denial reach the controller before the parking does.
    @Test("a refusal answered during the journal write never starts the feed")
    func refusalDuringTheJournalWriteNeverStartsTheWatch() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        let hikeRecorder = await recordingRecorder(harness)
        let write = TestGate()
        hikeRecorder.journalQueue.enqueue { await write.wait() }

        hikeRecorder.pause()
        await harness.controller.settle()
        write.open()
        await hikeRecorder.journalQueue.drain()

        #expect(source.movementWatchStarts == 0)
        #expect(source.stopCount == 1)
    }

    /// A hiker who leaves the prompt on screen, taps Resume, and refuses it
    /// half an hour later. The recording is running again by then, and
    /// parking its sensors would stop the walk being recorded.
    @Test("a refusal that lands after Resume leaves the recording running")
    func lateRefusalDoesNotParkAResumedRecording() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        let hikeRecorder = await recordingRecorder(harness)
        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()
        guard await harness.notifier.awaitPrompt() else { return }
        await hikeRecorder.resume()
        let stopsBefore = source.stopCount

        harness.notifier.answerPrompt(allowing: false)
        await harness.controller.settle()

        #expect(hikeRecorder.phase != .paused, "precondition: the hiker resumed")
        #expect(
            source.stopCount == stopsBefore,
            "a late answer is about the pause that asked, and that pause is over"
        )
    }

    /// The switch's version of the same race, and the one a hiker is far
    /// likelier to run into than a refusal: Settings is one swipe away while
    /// the pause's journal write is still in flight. The controller disarms
    /// itself and tells the recorder, but the recorder has not parked
    /// anything yet — so the parking, arriving afterwards, must not start a
    /// feed for a watch that no longer exists.
    @Test("a switch flipped during the journal write never starts the feed")
    func switchDuringTheJournalWriteNeverStartsTheWatch() async {
        let harness = MovementReminderHarness.harness()
        let hikeRecorder = await recordingRecorder(harness)
        let write = TestGate()
        hikeRecorder.journalQueue.enqueue { await write.wait() }

        hikeRecorder.pause()
        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.controller.reconcileWithPreferences()
        write.open()
        await hikeRecorder.journalQueue.drain()
        await harness.controller.settle()

        #expect(source.movementWatchStarts == 0)
        #expect(
            harness.controller.isWatchingPausedRecording == false,
            "the switch took the watch with it; the parking may not hand it back"
        )
        #expect(
            source.stopCount == 1,
            "the pause ends up as expensive as one taken with the switch already off"
        )
    }

    @Test("resuming stops the watch and takes the reminder down")
    func resumingStopsTheWatch() async {
        let harness = MovementReminderHarness.harness()
        let hikeRecorder = await recordingRecorder(harness)
        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()

        await hikeRecorder.resume()
        await harness.controller.settle()

        #expect(source.movementWatchStops >= 1)
        #expect(harness.notifier.withdrawn.contains(.resumeRecording))
    }
}
