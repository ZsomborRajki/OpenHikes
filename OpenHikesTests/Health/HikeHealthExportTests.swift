//
//  HikeHealthExportTests.swift
//  OpenHikesTests
//
//  Whether a finished hike reaches Health, and — mostly — whether it stays out
//  of it.
//
//  HealthKit is unavailable in a hosted unit test the way ActivityKit and
//  `StoreKitTest` are, and `makeWorkoutWriter()` answers `nil` for exactly
//  this launch, so nothing here touches a real Health store. That is the
//  reason ``HikeWorkoutWriting`` exists: every decision worth asserting — the
//  switch, the figures, the identifier filed afterwards — sits above it, and
//  the one file that speaks HealthKit sits below.
//
//  The bias of this suite is deliberate. Most of what matters about a Health
//  export is that it does not happen: not for a hiker who never asked, not
//  before the hike itself is safely saved, and not twice.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// Records what it was asked to write, and can be made to fail.
@MainActor
final class StubWorkoutWriter: HikeWorkoutWriting {
    private(set) var written: [HikeWorkoutRequest] = []
    private(set) var authorizationRequests = 0
    var isAuthorizationDetermined = true
    var result: Result<UUID, HikeWorkoutFailure> = .success(UUID())

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        await Task.yield()
        return true
    }

    func write(_ request: HikeWorkoutRequest) async throws -> UUID {
        written.append(request)
        // A hop, so the stub behaves like the real writer: a caller that
        // happens to be correct only because nothing suspended is a caller
        // that breaks on a device.
        await Task.yield()
        return try result.get()
    }

    /// What a deletion asked Health to remove, in the order it asked.
    private(set) var deleted: [UUID] = []
    /// What the next delete does. `nil` succeeds; a failure is what a caller
    /// has to be able to survive, since the hike is gone from the list either
    /// way.
    var deleteFailure: HikeWorkoutFailure?

    func delete(workoutID: UUID) async throws {
        deleted.append(workoutID)
        await Task.yield()
        if let deleteFailure { throw deleteFailure }
    }
}

@MainActor
@Suite("Hike Health export")
struct HikeHealthExportTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_757_000_000)

    /// Off is the default, and it is the whole opt-in.
    @Test("a hiker who never asked gets nothing written")
    func nothingIsWrittenByDefault() async throws {
        let harness = try harness(savesToHealth: .neverSet)
        _ = try harness.persist()
        await harness.settle()

        #expect(harness.writer.written.isEmpty)
    }

    @Test("turning the switch off again stops the next hike being written")
    func theSwitchIsReadAtEachSave() async throws {
        let harness = try harness(savesToHealth: .on)
        _ = try harness.persist()
        await harness.settle()
        #expect(harness.writer.written.count == 1)

        harness.defaults.set(false, forKey: SettingsKey.savesHikesToHealth)
        _ = try harness.persist(sessionID: UUID())
        await harness.settle()

        #expect(harness.writer.written.count == 1, "the switch is read at save, not captured")
    }

    @Test("a hike the hiker asked to export carries the figures the walk produced")
    func theRequestCarriesTheWalksOwnFigures() async throws {
        let harness = try harness(savesToHealth: .on)
        _ = try harness.persist()
        await harness.settle()

        let request = try #require(harness.writer.written.first)
        #expect(request.startedAt == Self.startedAt)
        #expect(request.distanceMeters == Harness.distanceMeters)
        // The recording's own elapsed time, not the wall clock: a paused lunch
        // must not be exported as an hour of hiking.
        #expect(
            request.endedAt == Self.startedAt.addingTimeInterval(Harness.recordedSeconds)
        )
        #expect(request.route.count == Harness.routePointCount)
    }

    /// The identifier names a record in *this* device's Health store, which is
    /// why it belongs on `HikeLocalState` rather than on the mirrored row.
    @Test("the workout identifier is filed against the hike once the write lands")
    func theWorkoutIdentifierIsRemembered() async throws {
        let harness = try harness(savesToHealth: .on)
        let workoutID = UUID()
        harness.writer.result = .success(workoutID)

        let hike = try harness.persist()
        await harness.settle()

        let state = HikeLocalState.existing(for: hike.id, in: harness.context)
        #expect(state?.healthWorkoutID == workoutID)
    }

    /// A failed write leaves nothing behind — no workout, no route, no
    /// half-finished builder — which is why this needs no owner and no sweep.
    @Test("a failed write leaves no identifier claiming one exists")
    func aFailedWriteRemembersNothing() async throws {
        let harness = try harness(savesToHealth: .on)
        harness.writer.result = .failure(.notWritten)

        let hike = try harness.persist()
        await harness.settle()

        let state = HikeLocalState.existing(for: hike.id, in: harness.context)
        #expect(state?.healthWorkoutID == nil)
    }

    /// The hike is what the hiker came for. Health is a second store and must
    /// never hold a walk this app does not.
    @Test("the hike is saved whether or not Health accepts it")
    func aFailedExportDoesNotCostTheHike() async throws {
        let harness = try harness(savesToHealth: .on)
        harness.writer.result = .failure(.unavailable)

        let hike = try harness.persist()
        await harness.settle()

        #expect(!hike.isRecording)
        #expect(hike.distanceMeters == Harness.distanceMeters)
    }

    // MARK: - Harness

    private func harness(savesToHealth: Harness.Switch) throws -> Harness {
        try Harness(savesToHealth: savesToHealth, startedAt: Self.startedAt)
    }

    @MainActor
    struct Harness {
        static let distanceMeters: Double = 5200
        static let recordedSeconds: TimeInterval = 4500
        static let routePointCount = 3

        let recorder: HikeRecorder
        let writer: StubWorkoutWriter
        let defaults: UserDefaults
        let context: ModelContext
        private let startedAt: Date

        /// Three states rather than a flag, because *never set* is the one
        /// the default exists for and is not the same as explicitly off.
        enum Switch {
            case neverSet
            case off
            case on
        }

        init(savesToHealth: Switch, startedAt: Date) throws {
            self.startedAt = startedAt
            let container = try Fixture.modelContainer()
            context = container.mainContext
            let suite = UserDefaults(suiteName: "health-export-\(UUID().uuidString)")
            defaults = suite ?? .standard
            switch savesToHealth {
            case .neverSet: break
            case .off: defaults.set(false, forKey: SettingsKey.savesHikesToHealth)
            case .on: defaults.set(true, forKey: SettingsKey.savesHikesToHealth)
            }
            let stub = StubWorkoutWriter()
            writer = stub
            recorder = HikeRecorder(
                container: container,
                source: StubRecordingLocationSource(),
                defaults: defaults,
                powerMonitor: PowerStateMonitor(
                    read: { PowerState() },
                    observesNotifications: false
                ),
                workoutWriter: stub,
                journalDirectory: nil,
                automaticallyRecovers: false
            )
        }

        /// The export is fire-and-forget, so a test has to let the task it
        /// starts run. Yielding rather than sleeping, for the reason every
        /// suite here does: waiting on a duration measures `Task.sleep`.
        func settle() async {
            for _ in 0..<10 { await Task.yield() }
        }

        func persist(sessionID: UUID = UUID()) throws -> Hike {
            try recorder.persist(
                Self.session(id: sessionID, startedAt: startedAt),
                prepared: prepared()
            )
        }

        private func prepared() -> PreparedRecording {
            let route = (0..<Self.routePointCount).map { index in
                RouteCoordinate(
                    latitude: 47.63 + Double(index) * 0.001,
                    longitude: 12.86,
                    elevation: 600 + Double(index),
                    timestamp: startedAt.addingTimeInterval(Double(index) * 60)
                )
            }
            return PreparedRecording(
                route: route,
                rawRoute: route,
                distanceMeters: Self.distanceMeters,
                routeLengthMeters: Self.distanceMeters,
                recordedSeconds: Self.recordedSeconds,
                startedAt: startedAt,
                matchedTrailName: nil,
                matchResult: nil
            )
        }

        private static func session(id: UUID, startedAt: Date) -> TrackJournalSession {
            TrackJournalSession(
                metadata: TrackJournalMetadata(
                    sessionID: id,
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(Self.recordedSeconds),
                    lastUpdatedAt: startedAt.addingTimeInterval(Self.recordedSeconds),
                    pausedIntervals: [],
                    title: nil
                ),
                points: []
            )
        }
    }
}
