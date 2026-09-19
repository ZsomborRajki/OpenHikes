//
//  WatchRecordingMirrorTests.swift
//  OpenHikesTests
//
//  What a watch sees of this phone's recording, and what its buttons do to it.
//
//  Driven through a real `HikeRecorder` behind a real `HikeIntentCoordinator`,
//  for the reason `HikeIntentCoordinatorTests` gives: what this can get wrong
//  is not arithmetic but believing a recording started when the recorder went
//  to `.failed` instead. Only the recorder produces those states, and it
//  produces them here with no ActivityKit, no App Group and no Core Location.
//
//  The publishing side is driven by calling `publishCurrentState()` rather
//  than by waiting for the loop: the loop's only job is to call it on a
//  cadence, and a test that slept for `updateFloorSeconds` would be a test
//  that waited twenty seconds to learn nothing. That is the "no fixed sleeps
//  as barriers" rule in the repository instructions — wait on the effect.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

@Suite("The phone's recording, mirrored to a watch")
final class WatchRecordingMirrorTests {
    private let container: ModelContainer
    private let source = StubRecordingLocationSource()
    private let clock = TestClock()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("watch-mirror-\(UUID().uuidString)", isDirectory: true)
    // periphery:ignore - the strong reference that keeps the recorder alive for
    // the length of the test; never read back.
    private var recorder: HikeRecorder?

    init() throws {
        container = try Fixture.modelContainer()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("with nothing recording, the watch is told idle")
    func nothingRecordingReadsIdle() async {
        let published = Published()
        let mirror = makeMirror(publishing: published)

        await mirror.publishCurrentState()

        #expect(published.readings.last?.state == .idle)
    }

    @Test("a running recording reaches the watch with the figures Siri speaks")
    func aRunningRecordingIsMirrored() async throws {
        let published = Published()
        let coordinator = makeCoordinator()
        let mirror = makeMirror(publishing: published, coordinator: coordinator)
        _ = try await coordinator.startRecording()
        walk()

        // Read first, so the comparison below is against the report this
        // reading was taken from rather than a later one.
        let report = try await coordinator.currentRecording()
        await mirror.publishCurrentState()

        let reading = try #require(published.readings.last)
        #expect(reading.state == .recording)
        // The same figures `LiveRecordingReport` carries, which is the point:
        // one description of a live recording, read by both surfaces.
        #expect(reading.distanceMeters == report.distance.converted(to: .meters).value)
        #expect(reading.trailName == report.trailName)
        #expect(reading.isTrailNameStale == report.isTrailNameStale)
        // Within a second rather than equal, and the tolerance is about the
        // *quantity* rather than about flakiness: `HikeRecorder.elapsedSeconds()`
        // is read off system uptime, so it genuinely moves between two
        // adjacent calls however the injected clock is frozen. What is being
        // asserted is that the watch is handed that number rather than zero
        // or a different one, which a second of slack cannot hide.
        #expect(abs(reading.elapsedSeconds - report.elapsed) < 1)
    }

    @Test("a reading that says nothing new is not sent again")
    func anUnchangedReadingCostsNothing() async throws {
        let published = Published()
        let coordinator = makeCoordinator()
        let mirror = makeMirror(publishing: published, coordinator: coordinator)
        _ = try await coordinator.startRecording()
        walk()

        await mirror.publishCurrentState()
        await mirror.publishCurrentState()
        await mirror.publishCurrentState()

        // `updatedAt` moves on every read, so equality would send on every
        // tick — a message every twenty seconds for six hours describing a
        // hiker who has not moved. The watch runs the clock itself.
        #expect(published.readings.count == 1)
    }

    @Test("pausing is sent even though the figures did not move")
    func aStateChangeIsAlwaysSent() async throws {
        let published = Published()
        let coordinator = makeCoordinator()
        let mirror = makeMirror(publishing: published, coordinator: coordinator)
        _ = try await coordinator.startRecording()
        walk()
        await mirror.publishCurrentState()
        _ = try await coordinator.pauseRecording()

        await mirror.publishCurrentState()

        #expect(published.readings.count == 2)
        #expect(published.readings.last?.state == .paused)
    }

    @Test("a button on the watch reaches the recorder and answers with the result")
    func aCommandDrivesTheRecorder() async {
        let coordinator = makeCoordinator()
        let mirror = makeMirror(publishing: Published(), coordinator: coordinator)
        let command = WatchRecordingCommand(action: .start)

        let outcome = await mirror.perform(command)

        #expect(outcome.commandID == command.id)
        #expect(outcome.refusal == nil)
        #expect(outcome.recording.state == .recording)
        #expect(source.startCount == 1)
    }

    @Test("pause and resume move the recorder through both states")
    func pauseAndResumeBothLand() async throws {
        let coordinator = makeCoordinator()
        let mirror = makeMirror(publishing: Published(), coordinator: coordinator)
        _ = try await coordinator.startRecording()
        walk()

        let paused = await mirror.perform(WatchRecordingCommand(action: .pause))
        #expect(paused.recording.state == .paused)

        let resumed = await mirror.perform(WatchRecordingCommand(action: .resume))
        #expect(resumed.recording.state == .recording)
    }

    @Test("a refusal comes back as a sentence, with the state that really holds")
    func aRefusalCarriesBothHalves() async throws {
        let coordinator = makeCoordinator()
        let mirror = makeMirror(publishing: Published(), coordinator: coordinator)
        _ = try await coordinator.startRecording()

        let outcome = await mirror.perform(WatchRecordingCommand(action: .start))

        // Asked to start a hike while one was already running. The hiker
        // should be told, *and* left looking at the hike that is running
        // rather than at an error beside a blank screen.
        #expect(outcome.refusal != nil)
        #expect(outcome.recording.state == .recording)
    }

    @Test("stopping ends the recording and reports idle")
    func stoppingEndsIt() async throws {
        let coordinator = makeCoordinator()
        let mirror = makeMirror(publishing: Published(), coordinator: coordinator)
        _ = try await coordinator.startRecording()
        walk()

        let outcome = await mirror.perform(WatchRecordingCommand(action: .stop))

        #expect(outcome.refusal == nil)
        #expect(outcome.recording.state == .idle)
    }

    @Test("with no coordinator registered, a button is refused rather than dropped")
    func withoutACoordinatorACommandIsRefused() async {
        let mirror = WatchRecordingMirror(coordinator: nil) { _ in /* nothing to collect */ }

        let outcome = await mirror.perform(WatchRecordingCommand(action: .start))

        // The watch has disabled the button it pressed until an answer
        // arrives; a command that quietly went nowhere would leave it that way.
        #expect(outcome.refusal != nil)
        #expect(outcome.recording.state == .idle)
    }

    // MARK: - Harness

    /// Collects what the mirror sent, in order.
    @MainActor
    private final class Published {
        private(set) var readings: [WatchPhoneRecording] = []

        func record(_ recording: WatchPhoneRecording) { readings.append(recording) }
    }

    private func makeMirror(
        publishing published: Published,
        coordinator: HikeIntentCoordinator? = nil
    ) -> WatchRecordingMirror {
        WatchRecordingMirror(coordinator: coordinator ?? makeCoordinator()) { recording in
            published.record(recording)
        }
    }

    private func makeCoordinator() -> HikeIntentCoordinator {
        let instance = HikeRecorder(
            container: container,
            source: source,
            defaults: UserDefaults(suiteName: "watch-mirror-\(UUID().uuidString)") ?? .standard,
            powerMonitor: PowerStateMonitor(read: { PowerState() }, observesNotifications: false),
            journalDirectory: directory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        recorder = instance
        return HikeIntentCoordinator(
            recorder: instance,
            container: container,
            calendar: Calendar(identifier: .gregorian),
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
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: 12.8600),
            altitude: 600,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: clock.read()
        )
    }
}
