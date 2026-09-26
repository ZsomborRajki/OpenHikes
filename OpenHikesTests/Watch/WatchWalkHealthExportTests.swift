//
//  WatchWalkHealthExportTests.swift
//  OpenHikesTests
//
//  Whether a walk from the watch reaches Health, and — as with the phone's own
//  recordings — mostly whether it stays out of it.
//
//  The watch discards the workout it builds, so the phone is the one writer.
//  What is pinned here is that the one writer writes once: on the arrival
//  that saved the walk, for a hiker who asked, and never for an arrival the
//  store refused or one it had already seen.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

@MainActor
@Suite("Walks from the watch reaching Health")
struct WatchWalkHealthExportTests {
    private typealias Fixture = WatchWalkImportTests.Fixture

    @Test("a saved walk is written once, with the track's figures and the watch's climb")
    func aSavedWalkIsWritten() async throws {
        let harness = try Harness(savesToHealth: .on)
        var walk = Fixture.walk()
        walk.elevationGainMeters = 120
        walk.elevationLossMeters = 80

        let outcome = await harness.arrive(walk)

        let request = try #require(harness.writer.written.first)
        #expect(harness.writer.written.count == 1)
        let hike = try #require(try Fixture.hike(request.hikeID, in: harness.container.mainContext))
        #expect(outcome == .imported(hike.id))
        #expect(request.startedAt == walk.startedAt)
        // The moving time, not the wall clock — the rule a phone recording's
        // request keeps too.
        #expect(request.endedAt == walk.startedAt.addingTimeInterval(walk.activeSeconds))
        // The saved hike's figure, which is measured from the track, rather
        // than the watch's own total.
        #expect(request.distanceMeters == hike.distanceMeters)
        #expect(request.route.count == walk.fixes.count)
        #expect(request.elevationGainMeters == 120)
        #expect(request.elevationLossMeters == 80)
    }

    @Test("the workout identifier is filed against the hike the walk became")
    func theWorkoutIdentifierIsRemembered() async throws {
        let harness = try Harness(savesToHealth: .on)
        let workoutID = UUID()
        harness.writer.result = .success(workoutID)

        let outcome = await harness.arrive(Fixture.walk())

        guard case .imported(let hikeID) = outcome else {
            Issue.record("Expected the walk to be imported, got \(outcome)")
            return
        }
        let state = HikeLocalState.existing(for: hikeID, in: harness.container.mainContext)
        #expect(state?.healthWorkoutID == workoutID)
    }

    @Test("a hiker who did not ask gets nothing written", arguments: [Harness.Switch.neverSet, .off])
    func nothingIsWrittenWithTheSwitchOff(savesToHealth: Harness.Switch) async throws {
        let harness = try Harness(savesToHealth: savesToHealth)

        let outcome = await harness.arrive(Fixture.walk())

        #expect(outcome.deservesReceipt)
        #expect(harness.writer.written.isEmpty)
    }

    /// Health must never hold a walk this app does not.
    @Test("a walk the store refused is not written")
    func aRefusedImportWritesNothing() async throws {
        let harness = try Harness(savesToHealth: .on)

        let outcome = await harness.arrive(Fixture.walk()) { _ in
            throw Fixture.RefusedSave()
        }

        #expect(outcome == .refused(.notSaved))
        #expect(harness.writer.written.isEmpty)
    }

    /// The case the watch discards its own workout for: one walk, one workout,
    /// however many times the transfer lands.
    @Test("the same walk arriving twice is written once")
    func aRedeliveryIsNotWrittenAgain() async throws {
        let harness = try Harness(savesToHealth: .on)
        let walk = Fixture.walk()

        let first = await harness.arrive(walk)
        let second = await harness.arrive(walk)

        guard case .imported(let hikeID) = first else {
            Issue.record("Expected the first arrival to be imported, got \(first)")
            return
        }
        #expect(second == .alreadyImported(hikeID))
        #expect(harness.writer.written.count == 1)
    }

    @Test("a failed write keeps the hike and files no identifier")
    func aFailedWriteCostsNothing() async throws {
        let harness = try Harness(savesToHealth: .on)
        harness.writer.result = .failure(.notWritten)

        let outcome = await harness.arrive(Fixture.walk())

        guard case .imported(let hikeID) = outcome else {
            Issue.record("Expected the walk to be imported, got \(outcome)")
            return
        }
        #expect(harness.writer.written.count == 1)
        #expect(try Fixture.hike(hikeID, in: harness.container.mainContext) != nil)
        let state = HikeLocalState.existing(for: hikeID, in: harness.container.mainContext)
        #expect(state?.healthWorkoutID == nil)
    }

    // MARK: - Harness

    /// The coordinator's own sequence — store, then export on its outcome —
    /// without the `WCSession` a suite cannot open.
    @MainActor
    struct Harness {
        enum Switch {
            /// A hiker who has never touched it — off, by
            /// ``SettingsDefault/savesHikesToHealth``.
            case neverSet
            case off
            case on
        }

        let container: ModelContainer
        let writer = StubWorkoutWriter()
        let export: WatchWalkHealthExport

        init(savesToHealth: Switch) throws {
            container = try Fixture.modelContainer()
            let defaults = UserDefaults(suiteName: "watch-health-export-\(UUID().uuidString)") ?? .standard
            switch savesToHealth {
            case .neverSet: break
            case .off: defaults.set(false, forKey: SettingsKey.savesHikesToHealth)
            case .on: defaults.set(true, forKey: SettingsKey.savesHikesToHealth)
            }
            export = WatchWalkHealthExport(
                writer: writer,
                container: container,
                defaults: defaults,
                weatherState: { .idle }
            )
        }

        func arrive(
            _ walk: WatchRecordedWalk,
            save: @Sendable (ModelContext) throws -> Void = { try $0.save() }
        ) async -> WatchWalkImportOutcome {
            let outcome = await WatchWalkImport.store(walk, in: container, save: save)
            await export.export(walk, after: outcome)
            return outcome
        }
    }
}
