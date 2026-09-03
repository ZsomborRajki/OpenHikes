//
//  HikeIntentCoordinatorTests.swift
//  OpenHikesTests
//
//  The recording half of the intents, driven through a real `HikeRecorder`
//  with a stub location source behind it.
//
//  A real recorder rather than a fake coordinator on purpose: what these
//  intents can get wrong is not arithmetic, it is believing a recording
//  started when the recorder went to `.failed` instead, or reporting a hike
//  saved when trail matching is still waiting for the walker. Only the
//  recorder can produce those states, and it produces them here with no
//  ActivityKit, no App Group and no Core Location — its `liveActivityController`
//  and `sharedStateStore` are left `nil` and its `source` is a stub.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Hike intent coordinator")
final class HikeIntentCoordinatorTests {
    private let container: ModelContainer
    private let source = StubRecordingLocationSource()
    private let clock = TestClock()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "intent-sandbox-\(UUID().uuidString)",
            isDirectory: true
        )
    // periphery:ignore - the strong reference that keeps the recorder alive for
    // the length of the test; never read back.
    private var recorder: HikeRecorder?

    init() throws {
        container = try Fixture.modelContainer()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Starting

    @Test("starting reports a recording underway")
    func startingBeginsARecording() async throws {
        let coordinator = makeCoordinator()

        let report = try await coordinator.startRecording()

        #expect(report.isPaused == false)
        #expect(source.startCount == 1)
        #expect(throws: Never.self) { try coordinator.currentRecording() }
    }

    @Test("starting a second time is refused rather than restarting")
    func startingTwiceIsRefused() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()

        await #expect(throws: HikeIntentFailure.alreadyRecording) {
            try await coordinator.startRecording()
        }
        // The recording that was already running is the one that matters: a
        // second start must not have reconfigured the GPS underneath it.
        #expect(source.startCount == 1)
    }

    @Test("denied location is reported instead of a recording that never began")
    func deniedLocationSurfacesAsAFailure() async throws {
        source.authorization = .denied
        let coordinator = makeCoordinator()

        // The recorder answers a refusal by moving to `.failed` rather than by
        // throwing, so an intent that only awaited `start()` would tell the
        // walker their hike was being recorded.
        await #expect(throws: HikeIntentFailure.recording(.locationDenied)) {
            try await coordinator.startRecording()
        }
    }

    @Test("a refusal the walker has since fixed starts on the second ask")
    func startingAgainAfterARefusalWorks() async throws {
        source.authorization = .denied
        let coordinator = makeCoordinator()
        await #expect(throws: HikeIntentFailure.recording(.locationDenied)) {
            try await coordinator.startRecording()
        }

        // Permission granted in Settings between the two asks. The recorder is
        // left in `.failed`, which `isActive` calls true — so a start gated on
        // that would answer "already recording" to somebody who has no hike.
        source.authorization = .authorized
        let report = try await coordinator.startRecording()

        #expect(report.distance.value == 0)
        #expect(source.startCount == 1)
    }

    @Test("an unasked location permission is visible before starting")
    func undecidedAuthorizationIsReportedUpFront() {
        source.authorization = .notDetermined

        #expect(makeCoordinator().authorization == .undecided)
    }

    // MARK: - Pausing and resuming

    @Test("pausing reports the distance walked so far")
    func pausingReportsProgress() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        walk()

        let report = try coordinator.pauseRecording()

        #expect(report.isPaused)
        #expect(report.distance.value > 0)
        #expect(report.elapsed > 0)
    }

    @Test("pausing nothing is refused")
    func pausingWithoutARecordingIsRefused() {
        let coordinator = makeCoordinator()

        #expect(throws: HikeIntentFailure.noActiveRecording) {
            try coordinator.pauseRecording()
        }
    }

    @Test("resuming a paused recording puts the GPS back on")
    func resumingRestartsTheSensors() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        walk()
        _ = try coordinator.pauseRecording()
        await settleJournal()

        let report = try await coordinator.resumeRecording()

        #expect(report.isPaused == false)
        #expect(source.startCount == 2)
    }

    @Test("resuming a recording that is running is refused")
    func resumingARunningRecordingIsRefused() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()

        await #expect(throws: HikeIntentFailure.notPaused) {
            try await coordinator.resumeRecording()
        }
    }

    // MARK: - Stopping

    @Test("stopping saves the hike and reports what was walked")
    func stoppingSavesTheHike() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()
        walk()

        let hike = try await coordinator.stopRecording()

        #expect(hike.distance.value > 0)
        #expect(throws: HikeIntentFailure.noActiveRecording) {
            try coordinator.currentRecording()
        }
        // Saved, not merely stopped: the row has to be in the store and no
        // longer flagged as a draft, which is what makes it the answer to
        // "what was my last hike".
        let saved = try coordinator.lastFinishedHike()
        #expect(saved.id == hike.id)
    }

    @Test("stopping nothing is refused")
    func stoppingWithoutARecordingIsRefused() async {
        let coordinator = makeCoordinator()

        await #expect(throws: HikeIntentFailure.noActiveRecording) {
            try await coordinator.stopRecording()
        }
    }

    // MARK: - Reporting on a live recording

    @Test("no recording means no progress to report")
    func noRecordingHasNoProgress() {
        let coordinator = makeCoordinator()

        #expect(throws: HikeIntentFailure.noActiveRecording) {
            try coordinator.currentRecording()
        }
    }

    @Test("a recording still waiting for its first fix already counts")
    func aRecordingWaitingForAFixIsReported() async throws {
        let coordinator = makeCoordinator()
        _ = try await coordinator.startRecording()

        // The walker started it and the GPS is on. "Nothing is being recorded"
        // would be a lie told during exactly the seconds they are most likely
        // to ask.
        let report = try coordinator.currentRecording()
        #expect(report.distance.value == 0)
    }

    // MARK: - Harness

    private func makeCoordinator(
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> HikeIntentCoordinator {
        let instance = HikeRecorder(
            container: container,
            source: source,
            defaults: UserDefaults(
                suiteName: "hike-intents-\(UUID().uuidString)"
            ) ?? .standard,
            powerMonitor: PowerStateMonitor(
                read: { PowerState() },
                observesNotifications: false
            ),
            journalDirectory: directory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        recorder = instance
        return HikeIntentCoordinator(
            recorder: instance,
            container: container,
            calendar: calendar,
            clock: clock.read
        )
    }

    /// Two fixes a minute and 200-odd metres apart, which is enough for the
    /// distance accumulator to call it walking rather than standing still.
    private func walk() {
        source.deliver(fix(latitude: 47.6300))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.6320))
    }

    private func fix(latitude: Double) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: 12.8600
            ),
            altitude: 600,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: clock.now
        )
    }

    /// Pausing hands the journal write to a serial queue, and resuming reopens
    /// the same file. Waiting on the effect — the recorder having actually
    /// stopped the sensors — rather than on a duration.
    private func settleJournal() async {
        while source.stopCount == 0 {
            await Task.yield()
        }
    }
}
