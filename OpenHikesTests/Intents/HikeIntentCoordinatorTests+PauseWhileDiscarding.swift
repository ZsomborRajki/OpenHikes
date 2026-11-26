//
//  HikeIntentCoordinatorTests+PauseWhileDiscarding.swift
//  OpenHikesTests
//
//  A Pause that reaches a recording a Stop is ending with nothing in it.
//  `discard()` lets go of the Start and throws the journal away before its
//  last wait, and leaves the phase as it was until the end, so for those
//  waits the recording still reads as one taking fixes. A Pause there used
//  to be told it landed, and queued a journal write that failed the
//  recording being ended with "No recording session is open": with the
//  Start's session still to be made, and with one made and already thrown
//  away. Now it is refused, as a Resume asked for there is, and the Stop
//  ends the recording as it would have.
//
//  The Stop is held in its last wait, clearing the shared state, which is
//  past the journal's discard and before the reset.
//

import Foundation
@testable import OpenHikes
import Testing

extension HikeIntentCoordinatorTests {
    @Test(
        "a Pause while a Stop ends a Start the hiker never answered is refused, and the Stop ends it",
        .timeLimit(.minutes(1))
    )
    func pauseWhileStopEndsTheUnansweredStartIsRefused() async throws {
        source.authorization = .notDetermined
        let sharedStore = BlockingClearRecordingSharedStateStore()
        let coordinator = makeCoordinator(sharedStateStore: sharedStore)
        let hikeRecorder = try #require(recorder)
        await hikeRecorder.start()
        let stopping = Task { try await coordinator.stopRecording() }
        await sharedStore.waitForClearToStart()
        // The Start is let go of, and the phase still says it is under way.
        #expect(!hikeRecorder.isAwaitingStartAnswer)
        #expect(hikeRecorder.phase == .waitingForFix)

        await expectPauseRefused(by: coordinator, recorder: hikeRecorder)

        await sharedStore.releaseClear()
        #expect(try await stopping.value == .endedEmpty)
        #expect(hikeRecorder.phase == .idle)
        #expect(source.startCount == 0)
    }

    @Test(
        "a Pause while a Stop ends an empty recording is refused, and the Stop ends it",
        .timeLimit(.minutes(1))
    )
    func pauseWhileStopEndsAnEmptyRecordingIsRefused() async throws {
        let sharedStore = BlockingClearRecordingSharedStateStore()
        let coordinator = makeCoordinator(sharedStateStore: sharedStore)
        let hikeRecorder = try #require(recorder)
        _ = try await coordinator.startRecording()
        #expect(hikeRecorder.sessionID != nil)
        let stopping = Task { try await coordinator.stopRecording() }
        await sharedStore.waitForClearToStart()
        #expect(hikeRecorder.phase == .waitingForFix)

        await expectPauseRefused(by: coordinator, recorder: hikeRecorder)

        await sharedStore.releaseClear()
        #expect(try await stopping.value == .endedEmpty)
        #expect(hikeRecorder.phase == .idle)
    }

    /// The watch's or Siri's Pause, then the recording bar's, which calls
    /// the recorder directly. Either one's journal write runs on the
    /// journal's queue; were one queued, it has failed the recording by the
    /// time the queue is drained.
    private func expectPauseRefused(
        by coordinator: HikeIntentCoordinator,
        recorder hikeRecorder: HikeRecorder
    ) async {
        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            _ = try await coordinator.pauseRecording()
        }
        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()
        #expect(hikeRecorder.phase == .waitingForFix)
    }
}
