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

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

/// Records what it was asked to write, and can be made to fail.
@MainActor
final class StubWorkoutWriter: HikeWorkoutWriting {
    private(set) var written: [HikeWorkoutRequest] = []
    var result: Result<UUID, HikeWorkoutFailure> = .success(UUID())

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
        // When the hiker pressed Stop, which the journal holds.
        #expect(
            request.endedAt == Self.startedAt.addingTimeInterval(Harness.recordedSeconds)
        )
        #expect(request.route.count == Harness.routePointCount)
    }

    /// Issue #721: 09:00 start, a pause from 10:00 to 11:00, Stop at 12:00.
    /// The workout used to end at 11:00 — start plus the two hours walked —
    /// with the last hour of its own route after it.
    @Test("a walk with a long pause keeps its real end, and the pause is taken out")
    func aLongPauseKeepsTheRealEnd() async throws {
        let hour: TimeInterval = 3600
        let harness = try harness(savesToHealth: .on)
        let route = Harness.route(
            from: Self.startedAt,
            at: [0, hour, 2 * hour, 3 * hour],
            resumingAt: 2
        )
        let stoppedAt = Self.startedAt.addingTimeInterval(3 * hour)

        _ = try harness.persist(route: route, stoppedAt: stoppedAt)
        await harness.settle()

        let request = try #require(harness.writer.written.first)
        #expect(request.startedAt == Self.startedAt)
        #expect(request.endedAt == stoppedAt)
        #expect(request.pauses == [DateInterval(start: Self.startedAt.addingTimeInterval(hour), duration: hour)])
        #expect(Self.activeSeconds(of: request) == 2 * hour)
        #expect(request.route.allSatisfy { point in
            point.timestamp.map { (request.startedAt...request.endedAt).contains($0) } ?? true
        })
    }

    @Test("a walk stopped while paused ends at Stop, paused to the end")
    func stoppingWhilePausedEndsAtStop() async throws {
        let hour: TimeInterval = 3600
        let harness = try harness(savesToHealth: .on)
        let route = Harness.route(from: Self.startedAt, at: [0, 1800, hour], resumingAt: nil)
        let stoppedAt = Self.startedAt.addingTimeInterval(2 * hour)

        _ = try harness.persist(route: route, stoppedAt: stoppedAt)
        await harness.settle()

        let request = try #require(harness.writer.written.first)
        #expect(request.endedAt == stoppedAt)
        #expect(request.pauses == [DateInterval(start: Self.startedAt.addingTimeInterval(hour), end: stoppedAt)])
        #expect(Self.activeSeconds(of: request) == hour)
    }

    /// What `HKWorkoutBuilder.elapsedTime(at:)` answers for this request once
    /// its pauses are events.
    private static func activeSeconds(of request: HikeWorkoutRequest) -> TimeInterval {
        request.endedAt.timeIntervalSince(request.startedAt)
            - request.pauses.reduce(0) { $0 + $1.duration }
    }

    /// Descent beside ascent, off the recording's own accumulator rather
    /// than re-derived from the saved line — the figures the hike shows.
    @Test("the request carries the descent as well as the climb")
    func theRequestCarriesTheDescent() async throws {
        let harness = try harness(savesToHealth: .on)
        for (step, elevation) in [600.0, 700, 640].enumerated() {
            harness.recorder.accumulator.append(
                RecordingPoint(
                    latitude: 47.63 + Double(step) * 0.001,
                    longitude: 12.86,
                    timestamp: Self.startedAt.addingTimeInterval(Double(step) * 60),
                    horizontalAccuracy: 8,
                    elevation: elevation
                )
            )
        }
        _ = try harness.persist()
        await harness.settle()

        let request = try #require(harness.writer.written.first)
        #expect(request.elevationGainMeters == 100)
        #expect(request.elevationLossMeters == 60)
    }

    /// The badge's reading is attached when it is about the hiker and was
    /// taken during the walk — the rule itself is `HikeWorkoutWeatherTests`'.
    @Test("a reading taken during the walk goes with it")
    func aReadingFromTheWalkIsAttached() async throws {
        let reading = WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 14, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: Self.startedAt.addingTimeInterval(600),
            conditions: .preview
        )
        let harness = try harness(
            savesToHealth: .on,
            weather: .reading(reading, subject: .me(.init(latitude: 47.63, longitude: 12.86)))
        )
        _ = try harness.persist()
        await harness.settle()

        let request = try #require(harness.writer.written.first)
        #expect(request.weather?.temperature == reading.temperature)
        #expect(request.weather?.humidity == reading.conditions.humidity)
    }

    /// A lunch stop longer than the badge's window puts the last reading
    /// well past start-plus-moving-time; it is still the walk's weather,
    /// because the walk ended when the hiker stopped it.
    @Test("a reading taken just before Stop goes with a walk that paused")
    func aReadingAfterAPauseIsAttached() async throws {
        let pause: TimeInterval = 3600
        let stoppedAt = Self.startedAt.addingTimeInterval(Harness.recordedSeconds + pause)
        let reading = WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 11, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: stoppedAt.addingTimeInterval(-300),
            conditions: .preview
        )
        let harness = try harness(
            savesToHealth: .on,
            weather: .reading(reading, subject: .me(.init(latitude: 47.63, longitude: 12.86))),
            pausedSeconds: pause
        )
        _ = try harness.persist()
        await harness.settle()

        let request = try #require(harness.writer.written.first)
        #expect(request.weather?.temperature == reading.temperature)
    }

    @Test("with no reading, the workout carries no weather")
    func noReadingMeansNoWeather() async throws {
        let harness = try harness(savesToHealth: .on)
        _ = try harness.persist()
        await harness.settle()

        let request = try #require(harness.writer.written.first)
        #expect(request.weather == nil)
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

    private func harness(
        savesToHealth: Harness.Switch,
        weather: WeatherBadgeState = .idle,
        pausedSeconds: TimeInterval = 0
    ) throws -> Harness {
        try Harness(
            savesToHealth: savesToHealth,
            startedAt: Self.startedAt,
            weather: weather,
            pausedSeconds: pausedSeconds
        )
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
        /// Time the walk stood paused, which the journal's wall-clock end
        /// includes and ``recordedSeconds`` does not.
        private let pausedSeconds: TimeInterval

        /// Three states rather than a flag, because *never set* is the one
        /// the default exists for and is not the same as explicitly off.
        enum Switch {
            case neverSet
            case off
            case on
        }

        init(
            savesToHealth: Switch,
            startedAt: Date,
            weather: WeatherBadgeState,
            pausedSeconds: TimeInterval
        ) throws {
            self.startedAt = startedAt
            self.pausedSeconds = pausedSeconds
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
                weatherState: { weather },
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

        /// The harness's own three points, a minute apart, and a journal
        /// ending ``recordedSeconds`` plus the pause after the start.
        func persist(sessionID: UUID = UUID()) throws -> Hike {
            try persist(
                route: Self.route(
                    from: startedAt,
                    at: (0..<Self.routePointCount).map { Double($0) * 60 },
                    resumingAt: nil
                ),
                stoppedAt: startedAt.addingTimeInterval(Self.recordedSeconds + pausedSeconds),
                sessionID: sessionID
            )
        }

        func persist(
            route: [RouteCoordinate],
            stoppedAt: Date,
            sessionID: UUID = UUID()
        ) throws -> Hike {
            try recorder.persist(
                Self.session(id: sessionID, startedAt: startedAt, endedAt: stoppedAt),
                prepared: prepared(route: route)
            )
        }

        /// Points `offsets` seconds after `start`, the one at `resumingAt`
        /// ending a pause — see ``RouteBoundary``.
        static func route(
            from start: Date,
            at offsets: [TimeInterval],
            resumingAt resumeIndex: Int?
        ) -> [RouteCoordinate] {
            offsets.enumerated().map { index, offset in
                RouteCoordinate(
                    latitude: 47.63 + Double(index) * 0.001,
                    longitude: 12.86,
                    elevation: 600 + Double(index),
                    timestamp: start.addingTimeInterval(offset),
                    boundary: index == resumeIndex ? .paused : nil
                )
            }
        }

        private func prepared(route: [RouteCoordinate]) -> PreparedRecording {
            PreparedRecording(
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

        private static func session(
            id: UUID,
            startedAt: Date,
            endedAt: Date
        ) -> TrackJournalSession {
            TrackJournalSession(
                metadata: TrackJournalMetadata(
                    sessionID: id,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    lastUpdatedAt: endedAt,
                    pausedIntervals: [],
                    title: nil
                ),
                points: []
            )
        }
    }
}
