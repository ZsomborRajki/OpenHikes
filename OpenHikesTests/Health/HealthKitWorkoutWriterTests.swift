//
//  HealthKitWorkoutWriterTests.swift
//  OpenHikesTests
//
//  What a Health write leaves in Health, and whether deleting the hike takes
//  all of it back.
//
//  The stubs in `HikeHealthExportTests` stand in for ``HikeWorkoutWriting``,
//  so they cannot reach what the writer itself decides: what a locked
//  phone's finish counts as, what a failure after the first sample takes
//  back, and what a deletion asks for. These run the real
//  `HealthKitWorkoutWriter` over ``HealthWorkoutStore`` instead, against a
//  store that holds what a write saves the way Health does and deletes
//  exactly what each predicate matches. No Health store is touched. The
//  objects and predicates here are HealthKit's own values, and building one
//  asks a store for nothing.
//

import CoreLocation
import Foundation
import HealthKit
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Health workout writer")
struct HealthKitWorkoutWriterTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_757_000_000)
    private static let walkSeconds: TimeInterval = 3600
    private static let walkMeters = 5000.0
    private static let climbMeters = 20.0

    private static let workout = HKObjectType.workoutType()
    private static let route = HKSeriesType.workoutRoute()
    private static let distance = HKQuantityType(.distanceWalkingRunning)

    /// A phone locked in a pocket while the watch's Stop saves the walk.
    /// Health keeps the workout and hands nothing back, which used to read as
    /// a write that never happened. Nothing was filed, so deleting the hike
    /// had nothing to ask Health with.
    @Test("a workout Health saved while the phone was locked goes with its hike")
    func aLockedFinishGoesWithItsHike() async throws {
        let store = ScriptedHealthStore()
        store.handsWorkoutBack = false
        let harness = try Harness(store: store)

        await harness.export()
        #expect(store.heldTypes == [Self.distance, Self.workout], "saved, with nothing taken back")

        try harness.deleteHike()
        await settleDelegateHop(until: "Health to be asked for the hike's write") { store.held.isEmpty }
        #expect(store.heldTypes.isEmpty, "Health still holds \(store.heldTypes)")
    }

    /// `addSamples` saves the distance as it is added, so a write that fails
    /// at any later step has already put a walk's distance in Health, with no
    /// workout around it.
    @Test(
        "a write that fails after its distance sample takes the sample back",
        arguments: [ScriptedHealthStore.Call.metadata, .end, .finish]
    )
    func aFailureAfterTheDistanceTakesItBack(at call: ScriptedHealthStore.Call) async throws {
        let store = ScriptedHealthStore()
        store.failing = call
        let harness = try Harness(store: store)

        await #expect(throws: ScriptedHealthStore.Refusal.self) {
            try await harness.writer.write(harness.request)
        }

        #expect(store.heldTypes.isEmpty, "Health still holds \(store.heldTypes)")
    }

    /// The other side of the one above: a failure before anything was saved
    /// has nothing to take back, so it asks Health for nothing.
    @Test("a write that fails before saving anything asks Health to delete nothing")
    func aFailureBeforeAnySaveAsksNothing() async throws {
        let store = ScriptedHealthStore()
        store.failing = .begin
        let harness = try Harness(store: store)

        await #expect(throws: ScriptedHealthStore.Refusal.self) {
            try await harness.writer.write(harness.request)
        }

        #expect(store.heldTypes.isEmpty, "Health still holds \(store.heldTypes)")
        #expect(store.deletions.isEmpty)
    }

    @Test("deleting a hike takes its workout, its route and its distance out of Health")
    func aDeletionTakesBackEverything() async throws {
        let store = ScriptedHealthStore()
        let harness = try Harness(store: store)

        await harness.export()
        #expect(store.heldTypes == [Self.distance, Self.workout, Self.route])

        try harness.deleteHike()
        await settleDelegateHop(until: "Health to be asked for the hike's write") { store.held.isEmpty }
        #expect(store.heldTypes.isEmpty, "Health still holds \(store.heldTypes)")
    }

    /// The tag is how a deletion finds them, so everything a write saves has
    /// to carry it, and the workout Health may never hand back most of all.
    @Test("everything a write saves carries its hike's identifier")
    func everythingCarriesItsHike() async throws {
        let store = ScriptedHealthStore()
        let harness = try Harness(store: store)

        await harness.export()

        #expect(store.held.count == 3)
        #expect(store.held.allSatisfy { $0.tag == harness.hike.id.uuidString })
    }

    /// A hiker can turn one type off in Health's own settings and leave the
    /// others on. The refusal for that one must not keep the rest.
    @Test("a type Health refuses to delete keeps only itself")
    func aRefusedTypeKeepsOnlyItself() async throws {
        let store = ScriptedHealthStore()
        let harness = try Harness(store: store)
        await harness.export()
        store.refusesDeleting = [Self.workout]

        try harness.deleteHike()
        await settleDelegateHop(until: "the route and the distance to go") {
            store.heldTypes == [Self.workout]
        }
        #expect(store.heldTypes == [Self.workout])
    }

    // MARK: - Harness

    /// A saved hike and a writer over `store`, paired the way the app pairs
    /// them.
    @MainActor
    private struct Harness {
        let container: ModelContainer
        let hike: Hike
        let writer: HealthKitWorkoutWriter

        init(store: ScriptedHealthStore) throws {
            container = try Fixture.modelContainer()
            hike = Fixture.hike(in: container.mainContext)
            try container.mainContext.save()
            writer = HealthKitWorkoutWriter(store: store)
        }

        /// An hour's walk with three timed points, which is enough for a
        /// route, and a climb, so the workout carries metadata of its own.
        var request: HikeWorkoutRequest {
            let start = HealthKitWorkoutWriterTests.startedAt
            let points = (0..<3).map { index in
                RouteCoordinate(
                    latitude: 47.63 + Double(index) * 0.001,
                    longitude: 12.86,
                    elevation: 600 + Double(index) * 10,
                    timestamp: start.addingTimeInterval(Double(index) * 1800)
                )
            }
            return HikeWorkoutRequest(
                hikeID: hike.id,
                startedAt: start,
                endedAt: start.addingTimeInterval(HealthKitWorkoutWriterTests.walkSeconds),
                pauses: [],
                distanceMeters: HealthKitWorkoutWriterTests.walkMeters,
                elevationGainMeters: HealthKitWorkoutWriterTests.climbMeters,
                elevationLossMeters: 0,
                weather: nil,
                route: points
            )
        }

        /// The export a recording's save and a walk from the watch both make.
        func export() async {
            await HikeWorkoutExport.write(request, with: writer, filingInto: container)
        }

        /// The list's deletion, asking this writer's Health.
        func deleteHike() throws {
            try HikeDeletion.delete([hike], workouts: writer)
        }
    }
}

/// A Health store that holds what a write saves, answers as a suite tells it
/// to, and deletes exactly what a predicate matches.
///
/// It holds things when `HKWorkoutBuilder.h` says Health does: the distance
/// once `addSamples` lands, the workout once `finishWorkout()` does, whether
/// or not it is handed back, and the route once it is finished. A deletion
/// removes the objects of its type that its predicate matches. The predicate
/// is evaluated on each object's `UUID` and `metadata`, the key paths
/// HealthKit's own predicates are written in.
///
/// Nothing cascades. Neither `HKHealthStore.h` nor Apple's pages on deleting
/// say that a workout takes its route or its samples with it, so a writer
/// that passes here does not rely on it.
@MainActor
final class ScriptedHealthStore: HealthWorkoutStore {
    /// A step of a write, for the write to fail at.
    nonisolated enum Call: Sendable, CustomTestStringConvertible {
        case begin, events, samples, metadata, end, finish, route

        var testDescription: String {
            switch self {
            case .begin: "beginCollection"
            case .events: "addWorkoutEvents"
            case .samples: "addSamples"
            case .metadata: "addMetadata"
            case .end: "endCollection"
            case .finish: "finishWorkout"
            case .route: "finishRoute"
            }
        }
    }

    /// What a scripted failure throws.
    nonisolated struct Refusal: Error {}

    /// Something Health holds.
    struct Object {
        let type: HKObjectType
        /// What a predicate is evaluated on.
        let fields: [String: Any]

        /// The identifier a write tagged this with, if it tagged it at all.
        var tag: String? {
            (fields["metadata"] as? [String: Any])?[HKMetadataKeyExternalUUID] as? String
        }
    }

    /// The step the next write fails at. It fails before the step has any
    /// effect.
    var failing: Call?
    /// `false` is a locked phone: the workout is saved, and nothing is
    /// handed back.
    var handsWorkoutBack = true
    /// Types Health refuses to delete from.
    var refusesDeleting: [HKObjectType] = []

    private(set) var held: [Object] = []
    /// Every type a deletion asked about, in order.
    private(set) var deletions: [HKObjectType] = []

    var heldTypes: [HKObjectType] { held.map(\.type) }

    var isHealthDataAvailable: Bool { true }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        .sharingAuthorized
    }

    func requestAuthorization(toShare types: Set<HKSampleType>) {
        Issue.record("a store that has already answered was asked again")
    }

    func workoutBuilder(for configuration: HKWorkoutConfiguration) -> any HealthWorkoutBuilding {
        Builder(store: self)
    }

    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        deletions.append(type)
        await Task.yield()
        if refusesDeleting.contains(type) { throw Refusal() }
        held.removeAll { $0.type == type && predicate.evaluate(with: $0.fields) }
    }

    /// One step of a write: a hop, as HealthKit's calls make, and the
    /// scripted failure if this is the step.
    private func answer(_ call: Call) async throws {
        await Task.yield()
        if failing == call { throw Refusal() }
    }

    private func hold(_ type: HKObjectType, uuid: UUID, metadata: [String: Any]) {
        held.append(Object(type: type, fields: ["UUID": uuid, "metadata": metadata]))
    }

    /// One write's builder.
    private final class Builder: HealthWorkoutBuilding {
        private let store: ScriptedHealthStore
        private var metadata: [String: Any] = [:]
        private var handedBack = false

        init(store: ScriptedHealthStore) {
            self.store = store
        }

        func beginCollection(at date: Date) async throws {
            try await store.answer(.begin)
        }

        func addWorkoutEvents(_ events: [HKWorkoutEvent]) async throws {
            try await store.answer(.events)
        }

        /// Saved as they are added, which is what `HKWorkoutBuilder.h` says.
        func addSamples(_ samples: [HKSample]) async throws {
            try await store.answer(.samples)
            for sample in samples {
                store.hold(sample.sampleType, uuid: sample.uuid, metadata: sample.metadata ?? [:])
            }
        }

        func addMetadata(_ metadata: [String: Any]) async throws {
            try await store.answer(.metadata)
            self.metadata.merge(metadata) { _, added in added }
        }

        func endCollection(at date: Date) async throws {
            try await store.answer(.end)
        }

        /// Saved whether or not it is handed back: a locked phone's answer is a
        /// workout in Health all the same.
        func finishWorkout() async throws -> UUID? {
            try await store.answer(.finish)
            let workoutID = UUID()
            store.hold(HKObjectType.workoutType(), uuid: workoutID, metadata: metadata)
            handedBack = store.handsWorkoutBack
            return handedBack ? workoutID : nil
        }

        func finishRoute(_ locations: [CLLocation], metadata: [String: Any]) async throws {
            try await store.answer(.route)
            guard handedBack else { return }
            store.hold(HKSeriesType.workoutRoute(), uuid: UUID(), metadata: metadata)
        }
    }
}
