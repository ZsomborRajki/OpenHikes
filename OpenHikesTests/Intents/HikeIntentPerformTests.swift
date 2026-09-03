//
//  HikeIntentPerformTests.swift
//  OpenHikesTests
//
//  The `AppIntent`s themselves, performed.
//
//  What is not covered here is what the walker *hears*: `perform()` returns an
//  opaque `some IntentResult & ProvidesDialog`, so the dialog it carries
//  cannot be read back from a caller. The wording is asserted where it is
//  built instead — see `HikeIntentPhrasingTests`. What these pin is the half
//  that only running an intent can show: that it resolves a coordinator at
//  all, that it reaches the recorder, and that a refusal comes back as the
//  refusal rather than as a crash inside the property wrapper.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Hike intents")
final class HikeIntentPerformTests {
    private let container: ModelContainer
    private let source = StubRecordingLocationSource()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "intent-perform-\(UUID().uuidString)",
            isDirectory: true
        )
    // periphery:ignore - as in `HikeIntentCoordinatorTests`.
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

    @Test("the start intent starts the recorder it was given")
    func startIntentReachesTheRecorder() async throws {
        try await withCoordinator {
            _ = try await StartHikeRecordingIntent().perform()
        }

        #expect(source.startCount == 1)
    }

    @Test("the stop intent refuses when nothing is being recorded")
    func stopIntentRefusesWithoutARecording() async throws {
        try await withCoordinator {
            await #expect(throws: HikeIntentFailure.noActiveRecording) {
                _ = try await StopHikeRecordingIntent().perform()
            }
        }
    }

    @Test("the progress intent refuses when nothing is being recorded")
    func progressIntentRefusesWithoutARecording() async throws {
        try await withCoordinator {
            await #expect(throws: HikeIntentFailure.noActiveRecording) {
                _ = try await CurrentHikeProgressIntent().perform()
            }
        }
    }

    @Test("the last-hike intent says the store is empty rather than failing oddly")
    func lastHikeIntentReportsAnEmptyStore() async throws {
        try await withCoordinator {
            await #expect(throws: HikeIntentFailure.noHikesYet) {
                _ = try await LastHikeIntent().perform()
            }
        }
    }

    @Test("starting before location has ever been asked does not begin a recording")
    func startIntentDefersWhenPermissionWasNeverAsked() async throws {
        source.authorization = .notDetermined

        try await withCoordinator {
            // The thrown error is AppIntents' own "continue in the foreground",
            // not a `HikeIntentFailure`, so what is asserted is the guarantee
            // rather than the type: nothing was started behind a prompt the
            // walker never saw.
            await #expect(throws: (any Error).self) {
                _ = try await StartHikeRecordingIntent().perform()
            }
        }

        #expect(source.startCount == 0)
    }

    // MARK: - Harness

    /// Runs `body` with the intents resolving to a coordinator over this
    /// suite's own recorder and store. Nothing is registered with
    /// `AppDependencyManager`, which is what a real launch does — and an intent
    /// that reached for one here would trap rather than quietly pass.
    private func withCoordinator(
        _ body: () async throws -> Void
    ) async throws {
        let instance = HikeRecorder(
            container: container,
            source: source,
            defaults: UserDefaults(
                suiteName: "hike-intent-perform-\(UUID().uuidString)"
            ) ?? .standard,
            powerMonitor: PowerStateMonitor(
                read: { PowerState() },
                observesNotifications: false
            ),
            journalDirectory: directory,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        recorder = instance
        let coordinator = HikeIntentCoordinator(
            recorder: instance,
            container: container
        )
        try await HikeIntentContext.$override.withValue(coordinator) {
            try await body()
        }
    }
}
