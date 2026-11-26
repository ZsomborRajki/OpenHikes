//
//  HikeIntentCoordinatorTests+Permission.swift
//  OpenHikesTests
//
//  A start on an install that has never asked for location. The recorder
//  puts up the prompt and returns with no session behind it, and the
//  coordinator used to read that as a recording under way: Siri said
//  "Recording your hike" over a prompt the hiker then declined. It now waits
//  for the answer and reports that, and the watch, which cannot put the
//  phone's prompt up, is told why nothing started. A Start whose intent is
//  cancelled at the prompt goes with it, and a second Start, or a Stop,
//  while the prompt is up is answered for what it is.
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
    @Test(
        "a start that puts up the location prompt reports a recording only once it is allowed",
        .timeLimit(.minutes(1))
    )
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

    @Test(
        "a start whose location prompt is declined reports the refusal, not a recording",
        .timeLimit(.minutes(1))
    )
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

    /// Allow at approximate location brings the precision sheet, from the
    /// activation the answer began rather than from inside `start()`. The
    /// start is still the hiker's question there, and is reported once that
    /// sheet has its answer too.
    @Test(
        "a start allowed at approximate location waits for the precision sheet as well",
        .timeLimit(.minutes(1))
    )
    func startWaitsThroughThePrecisionSheet() async throws {
        source.authorization = .notDetermined
        source.holdsFullAccuracyRequests = true
        let coordinator = makeCoordinator()
        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the start to put up the prompt") {
            self.source.authorizationRequests == 1
        }

        source.authorization = .authorized
        source.hasFullAccuracy = false
        recorder?.locationManagerDidChangeAuthorization(CLLocationManager())
        await settleDelegateHop(until: "the Allow to put up the precision sheet") {
            self.source.fullAccuracyRequests == 1
        }
        #expect(recorder?.sessionID == nil, "nothing is recording behind the precision sheet")

        source.answerFullAccuracyRequests(granted: false)
        await #expect(throws: HikeIntentFailure.recording(.preciseLocationRequired)) {
            _ = try await starting.value
        }
        #expect(source.startCount == 0)
    }

    /// The prompt is the phone's, and a phone in a pocket cannot show it.
    @Test(
        "a watch's Start on an unasked phone is refused with why, and asks nothing",
        .timeLimit(.minutes(1))
    )
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

    /// What stands in the way first is named first: ending the walk is the
    /// hiker's next step, and the permission only matters after it.
    @Test(
        "a watch's Start mid-walk on an unasked phone names the walk, not the permission",
        .timeLimit(.minutes(1))
    )
    func watchStartMidWalkNamesTheWalk() async {
        source.authorization = .notDetermined
        let coordinator = makeCoordinator(walkUnderWay: "Ridge Loop")
        let mirror = WatchRecordingMirror(coordinator: coordinator) { _ in /* nothing to collect */ }

        let outcome = await mirror.perform(WatchRecordingCommand(action: .start))

        #expect(outcome.refusal == HikeIntentFailure.walking(trail: "Ridge Loop").errorDescription)
        #expect(source.authorizationRequests == 0)
    }

    /// Siri or Shortcuts stopped waiting while the prompt was up: the hiker
    /// cancelled, or the system gave up on the request. The Start goes with
    /// it, so an Allow tapped afterwards answers the question and starts
    /// nothing behind a request that had already ended.
    @Test(
        "a start whose intent is cancelled at the prompt is withdrawn, and a later Allow records nothing",
        .timeLimit(.minutes(1))
    )
    func aCancelledStartIsWithdrawn() async throws {
        source.authorization = .notDetermined
        let coordinator = makeCoordinator()
        let hikeRecorder = try #require(recorder)

        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the start to put up the prompt") {
            self.source.authorizationRequests == 1
        }
        starting.cancel()
        await #expect(throws: HikeIntentFailure.needsLocationPermission) {
            _ = try await starting.value
        }
        #expect(hikeRecorder.phase == .idle)

        source.authorization = .authorized
        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        // Barriers rather than a condition, because the effect being ruled
        // out has no counterpart when the fix holds. The round trip runs the
        // callback's hop; were it to begin an activation, that activation is
        // then queued on the journal ahead of this read, and is back on the
        // main actor, drafting and starting the GPS, before the read is.
        await settleDelegateHop()
        _ = try await hikeRecorder.journal?.loadSession()

        #expect(hikeRecorder.sessionID == nil)
        #expect(hikeRecorder.phase == .idle)
        #expect(source.startCount == 0)
    }

    /// "Already recording", said over the prompt, is the sentence #1655 took
    /// away from the first Start. A second is told what the recording waits
    /// on, and leaves the first to its answer.
    @Test(
        "a second start while the prompt is up is told it waits on location, not that it is recording",
        .timeLimit(.minutes(1))
    )
    func aSecondStartAtThePromptIsToldWhy() async throws {
        source.authorization = .notDetermined
        let coordinator = makeCoordinator()
        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the first start to put up the prompt") {
            self.source.authorizationRequests == 1
        }

        await #expect(throws: HikeIntentFailure.needsLocationPermission) {
            _ = try await coordinator.startRecording()
        }
        #expect(source.authorizationRequests == 1, "and puts up no second prompt")

        source.authorization = .authorized
        recorder?.locationManagerDidChangeAuthorization(CLLocationManager())
        let report = try await starting.value
        #expect(!report.isPaused)
        #expect(recorder?.sessionID != nil)
    }

    /// To the watch and to Siri, a Start waiting on the prompt is the
    /// recording it is about to be, and their Stop ends it. The Start that
    /// was waiting is told nothing is recording, rather than that a last
    /// recording is still being finished.
    @Test(
        "a start ended by a Stop while its prompt is up reports that nothing is recording",
        .timeLimit(.minutes(1))
    )
    func aStartStoppedAtThePromptReportsNothingRecording() async throws {
        source.authorization = .notDetermined
        let coordinator = makeCoordinator()
        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the start to put up the prompt") {
            self.source.authorizationRequests == 1
        }

        #expect(try await coordinator.stopRecording() == .endedEmpty)

        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            _ = try await starting.value
        }
        #expect(recorder?.phase == .idle)
        #expect(source.startCount == 0)
    }

    /// The precision sheet an approximate-only grant meets is waited for
    /// inside `start()`, not in the wait for the prompt's answer, and an
    /// intent cancelled there is withdrawn all the same: a grant arriving
    /// afterwards makes no session and starts no GPS.
    @Test(
        "a start whose intent is cancelled at the precision sheet is withdrawn, and a later grant records nothing",
        .timeLimit(.minutes(1))
    )
    func aStartCancelledAtThePrecisionSheetIsWithdrawn() async throws {
        source.hasFullAccuracy = false
        source.holdsFullAccuracyRequests = true
        let coordinator = makeCoordinator()
        let hikeRecorder = try #require(recorder)
        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the start to put up the precision sheet") {
            self.source.fullAccuracyRequests == 1
        }

        starting.cancel()
        // The withdrawal hops to the main actor from wherever the cancel ran.
        await settleDelegateHop(until: "the cancellation to withdraw the Start") {
            !hikeRecorder.isAwaitingStartAnswer
        }
        source.answerFullAccuracyRequests(granted: true)

        await #expect(throws: HikeIntentFailure.needsLocationPermission) {
            _ = try await starting.value
        }
        await settleDelegateHop(until: "the withdrawal to end the Start") { hikeRecorder.phase == .idle }
        #expect(hikeRecorder.sessionID == nil)
        #expect(source.startCount == 0)
    }

    /// A Pause has nothing to pause until the hiker allows the Start: taken
    /// here, the Allow would make the session and run it anyway, under a
    /// Pause the hiker was told had landed.
    @Test(
        "a Pause while the start's prompt is up is refused, and the Allow starts a recording that runs",
        .timeLimit(.minutes(1))
    )
    func aPauseAtThePromptIsRefused() async throws {
        source.authorization = .notDetermined
        let coordinator = makeCoordinator()
        let starting = Task { try await coordinator.startRecording() }
        await settleDelegateHop(until: "the start to put up the prompt") {
            self.source.authorizationRequests == 1
        }

        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            _ = try await coordinator.pauseRecording()
        }
        #expect(recorder?.phase == .waitingForFix)

        source.authorization = .authorized
        recorder?.locationManagerDidChangeAuthorization(CLLocationManager())
        let report = try await starting.value
        #expect(!report.isPaused)
        #expect(recorder?.phase == .waitingForFix)
    }
}
