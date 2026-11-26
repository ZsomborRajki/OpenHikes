//
//  HikeIntentCoordinatorTests+PauseBeforeSession.swift
//  OpenHikesTests
//
//  A Pause that reaches a Start still waiting on the hiker's answer, at the
//  location prompt or at the precision sheet (#1683). The Start reads as
//  recording, finding GPS, but there is no session behind it yet, so no
//  journal: the Pause used to mark one that did not exist, and failed the
//  Start with a storage error that left the answer, when it came, starting
//  nothing. Now a Pause there is refused, and the Start goes on to its answer.
//
//  The phone's Start is the recording screen's, `start()` on the recorder,
//  because that is the one the watch sees and offers Pause for: a watch's
//  own Start on an unasked phone is refused before it asks anything.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

extension HikeIntentCoordinatorTests {
    /// The watch shows the Start as the recording it is about to be, and
    /// offers Pause. Its reply says what the recording waits on, beside the
    /// reading it shows, rather than that nothing is recording.
    @Test(
        "a watch's Pause while the phone's location prompt is up is refused with why, and the Allow records",
        .timeLimit(.minutes(1))
    )
    func watchPauseAtThePromptIsRefused() async throws {
        source.authorization = .notDetermined
        // Held here: the mirror holds its coordinator weakly.
        let coordinator = makeCoordinator()
        let mirror = WatchRecordingMirror(coordinator: coordinator) { _ in /* nothing to collect */ }
        let hikeRecorder = try #require(recorder)
        await hikeRecorder.start()
        #expect(source.authorizationRequests == 1)

        let outcome = await mirror.perform(WatchRecordingCommand(action: .pause))

        #expect(outcome.refusal == HikeIntentFailure.needsLocationPermission.errorDescription)
        #expect(outcome.recording.state == .recording, "the Start still reads as the recording it will be")
        #expect(hikeRecorder.phase == .waitingForFix)

        source.authorization = .authorized
        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        await hikeRecorder.settleStart()
        #expect(hikeRecorder.sessionID != nil)
        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(source.startCount == 1)
    }

    /// Allowed at approximate location, the Start waits on the precision
    /// sheet, still with no session: the same refusal, and the same Start
    /// once the sheet is answered.
    @Test(
        "a Pause while the start's precision sheet is up is refused with why, and the grant records",
        .timeLimit(.minutes(1))
    )
    func pauseAtThePrecisionSheetIsRefused() async throws {
        source.hasFullAccuracy = false
        source.holdsFullAccuracyRequests = true
        let coordinator = makeCoordinator()
        let hikeRecorder = try #require(recorder)
        let starting = Task { await hikeRecorder.start() }
        await settleDelegateHop(until: "the start to put up the precision sheet") {
            self.source.fullAccuracyRequests == 1
        }

        await #expect(throws: HikeIntentFailure.needsLocationPermission) {
            _ = try await coordinator.pauseRecording()
        }
        #expect(hikeRecorder.phase == .waitingForFix)

        source.answerFullAccuracyRequests(granted: true)
        await starting.value
        #expect(hikeRecorder.sessionID != nil)
        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(source.startCount == 1)
    }

    /// The recording bar's and the map capsule's Pause call the recorder
    /// directly. Neither offers Pause before the session, but a tap that
    /// reaches it anyway — a Mac's prompt is a window beside the app's — is
    /// a Pause of nothing, and leaves the Start to its answer.
    @Test(
        "the recorder's own Pause before the session does nothing, and the Allow records",
        .timeLimit(.minutes(1))
    )
    func recorderPauseBeforeTheSessionDoesNothing() async throws {
        source.authorization = .notDetermined
        _ = makeCoordinator()
        let hikeRecorder = try #require(recorder)
        await hikeRecorder.start()

        hikeRecorder.pause()
        #expect(hikeRecorder.phase == .waitingForFix)
        // The write a Pause queues runs on the journal's queue; were one
        // queued, it has failed the Start by the time the queue is drained.
        await hikeRecorder.journalQueue.drain()
        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(hikeRecorder.isAwaitingStartAnswer)

        source.authorization = .authorized
        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        await hikeRecorder.settleStart()
        #expect(hikeRecorder.sessionID != nil)
        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(source.startCount == 1)
    }
}
