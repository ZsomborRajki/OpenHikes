//
//  HikeIntentCoordinatorTests+Resume.swift
//  OpenHikesTests
//
//  A Resume from Siri, the panel or the watch that the walk was discarded
//  under while it waited on the precision prompt (#1608).
//
//  The recorder's Resume returns having done nothing then, and leaves no
//  failure to read. The coordinator read that as success: Siri said "You're
//  0 meters in", and the panel counted the tap done. The recorder's half is
//  `HikeRecorderTests+ResumeOwnership`.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

extension HikeIntentCoordinatorTests {
    /// A coordinator with a walk two fixes in and paused, whose next Resume
    /// will wait on the precision prompt until it is answered.
    private func pausedWalkMeetingPrecisionPrompt() async throws -> (HikeIntentCoordinator, HikeRecorder) {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        walk()
        _ = try await coordinator.pauseRecording()
        await settleDelegateHop(until: "the pause to stop the GPS") { self.source.stopCount == 1 }
        source.hasFullAccuracy = false
        source.holdsFullAccuracyRequests = true
        return (coordinator, try #require(recorder))
    }

    @Test("a Resume the walk was discarded under is refused, not reported as recording")
    func resumeOvertakenByDiscardIsRefused() async throws {
        let (coordinator, paused) = try await pausedWalkMeetingPrecisionPrompt()
        let resuming = Task { try await coordinator.resumeRecording() }
        await settleDelegateHop(until: "Resume to ask for precise location") {
            self.source.fullAccuracyRequests == 1
        }

        await paused.discard()
        source.answerFullAccuracyRequests(granted: false)

        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            try await resuming.value
        }
        #expect(paused.phase == .idle)
    }

    @Test("the panel's Resume the walk was discarded under says nothing is recording")
    func panelResumeOvertakenByDiscardIsRefused() async throws {
        let (coordinator, paused) = try await pausedWalkMeetingPrecisionPrompt()
        let tapping = Task { await coordinator.performHikeActivityControl(.resume) }
        await settleDelegateHop(until: "Resume to ask for precise location") {
            self.source.fullAccuracyRequests == 1
        }

        await paused.discard()
        source.answerFullAccuracyRequests(granted: true)

        #expect(await tapping.value == .refused(.notRecording))
        #expect(paused.phase == .idle)
        #expect(source.startCount == 1, "no GPS for the walk thrown away")
    }

    /// The precondition the two above lean on: nothing overtook the Resume,
    /// and it is reported as recording once precise location is granted.
    @Test("a Resume nothing overtook is reported as recording once precision is granted")
    func resumeAnsweredByPrecisionIsReported() async throws {
        let (coordinator, _) = try await pausedWalkMeetingPrecisionPrompt()
        let resuming = Task { try await coordinator.resumeRecording() }
        await settleDelegateHop(until: "Resume to ask for precise location") {
            self.source.fullAccuracyRequests == 1
        }

        source.answerFullAccuracyRequests(granted: true)

        let report = try await resuming.value
        #expect(report.isPaused == false)
        #expect(source.startCount == 2)
    }
}
