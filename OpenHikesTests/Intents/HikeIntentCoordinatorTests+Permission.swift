//
//  HikeIntentCoordinatorTests+Permission.swift
//  OpenHikesTests
//
//  A start on an install that has never asked for location. The recorder
//  puts up the prompt and returns with no session behind it, and the
//  coordinator used to read that as a recording under way: Siri said
//  "Recording your hike" over a prompt the hiker then declined. It now waits
//  for the answer and reports that, and the watch, which cannot put the
//  phone's prompt up, is told why nothing started.
//
//  Driven through the location seam: the stub source counts the prompt and
//  the recorder's own authorization callback delivers the answer.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

extension HikeIntentCoordinatorTests {
    @Test("a start that puts up the location prompt reports a recording only once it is allowed")
    func startWaitsForAnAllowedPrompt() async throws {
        source.authorization = .notDetermined
        let coordinator = makeCoordinator()

        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the start to put up the prompt") {
            self.source.authorizationRequests == 1
        }
        let hikeRecorder = try #require(recorder)
        #expect(hikeRecorder.sessionID == nil, "nothing is recording behind the prompt")

        source.authorization = .authorized
        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        let report = try await starting.value

        #expect(hikeRecorder.sessionID != nil)
        #expect(!report.isPaused)
        #expect(source.startCount == 1)
    }

    @Test("a start whose location prompt is declined reports the refusal, not a recording")
    func startReportsADeclinedPrompt() async throws {
        source.authorization = .notDetermined
        let coordinator = makeCoordinator()

        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the start to put up the prompt") {
            self.source.authorizationRequests == 1
        }
        source.authorization = .denied
        recorder?.locationManagerDidChangeAuthorization(CLLocationManager())

        await #expect(throws: HikeIntentFailure.recording(.locationDenied)) {
            _ = try await starting.value
        }
        #expect(recorder?.sessionID == nil)
        #expect(source.startCount == 0)
    }

    /// The prompt is the phone's, and a phone in a pocket cannot show it.
    @Test("a watch's Start on an unasked phone is refused with why, and asks nothing")
    func watchStartOnAnUnaskedPhoneIsRefused() async {
        source.authorization = .notDetermined
        // Held here: the mirror holds its coordinator weakly.
        let coordinator = makeCoordinator()
        let mirror = WatchRecordingMirror(coordinator: coordinator) { _ in /* nothing to collect */ }

        let outcome = await mirror.perform(WatchRecordingCommand(action: .start))
        #expect(coordinator.authorization == .undecided, "and the phone still unasked")

        #expect(outcome.refusal == HikeIntentFailure.needsLocationPermission.errorDescription)
        #expect(outcome.recording.state == .idle)
        #expect(source.authorizationRequests == 0)
        #expect(recorder?.phase == .idle)
    }
}
