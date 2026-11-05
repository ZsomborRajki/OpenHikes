//
//  HikeListElevationFailedFetchTests.swift
//  OpenHikesTests
//
//  A fetch that fails spends no change, and a row that is gone owes no
//  figures (#1315): see the header of `HikeListMetrics+Observation.swift`.
//
//  A real store does not fail a fetch on demand, so the measuring seam
//  wraps the real measurement and answers the hikes it is told to fail as a
//  failed fetch does. Each line is saved elsewhere, as an edit mirrored in
//  from another device is, because that save wakes the list's task once:
//  only the pass a failure asks for can measure the line again.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Synchronization
import Testing

@Suite("Library elevation, when a fetch fails")
struct HikeListElevationFailedFetchTests {
    private struct FetchFailure: Error {}

    private struct Watching {
        let stage: HikeListElevationStage
        let fetches: FailingFetches
        let looks: LandedLooks
        let task: Task<Void, Never>

        /// The hikes each measurement after the first pass was handed.
        var measuredSinceFirstPass: [[UUID]] { Array(fetches.calls.dropFirst()) }
    }

    /// The stage's library with the list's task running, and its first pass
    /// published.
    private func watching() async throws -> Watching {
        let stage = try await HikeListElevationStage(hostingTheList: true)
        let fetches = FailingFetches()
        let looks = LandedLooks()
        let task = Task {
            await HikeListMetrics.observeElevation(
                in: stage.hikes,
                container: stage.container,
                measuring: fetches.measure,
                checking: looks.look
            ) {
                stage.didPublish()
            }
        }
        await settleDelegateHop(until: "the first pass is published") { stage.publications == 1 }
        return Watching(stage: stage, fetches: fetches, looks: looks, task: task)
    }

    private func saveElsewhere(climbing climb: Double, on index: Int, in stage: HikeListElevationStage) async throws {
        try await SelectedLineStoreWatchTests.saveElsewhere(stage.hikes[index].id, in: stage.container) { hike in
            hike.replaceRoute(with: HikeListElevationStage.line(index, climb: climb))
        }
    }

    @Test("a line whose fetch fails is measured again at once, with no other save, and is owed nothing after")
    func aFailedFetchIsMeasuredAgainAtOnce() async throws {
        let watching = try await watching()
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }
        let edited = stage.hikes[1]
        let other = stage.hikes[2]

        watching.fetches.fail(edited.id, times: 1)
        try await saveElsewhere(climbing: 500, on: 1, in: stage)
        await settleDelegateHop(until: "the new line is published, with no other save") {
            stage.has(edited, climbing: 500)
        }

        // Every pass measures what is owed, so a hike still owed once its
        // figures had landed would cost every later save a read of its line.
        try await saveElsewhere(climbing: 400, on: 2, in: stage)
        await settleDelegateHop(until: "the other new line is published") { stage.has(other, climbing: 400) }
        #expect(watching.measuredSinceFirstPass == [[edited.id], [edited.id], [other.id]])
    }

    /// Passes run one at a time, so a line saved afterwards being published
    /// says the pass before it is over, and any pass that one asked for. An
    /// owed hike is measured once a wake, before the look says what else is
    /// due. A failure is counted in the seam, before the task has its
    /// answer, so the next save waits for the retry pass's look to land: a
    /// save before it would be named by that look rather than its own wake.
    @Test("a failure that holds keeps the old figures and asks for one more pass, and no more")
    func aFailureThatHoldsAsksForOneMorePass() async throws {
        let watching = try await watching()
        let stage = watching.stage
        defer { stage.close() }
        defer { watching.task.cancel() }
        let edited = stage.hikes[1]
        let other = stage.hikes[2]
        let later = stage.hikes[3]

        watching.fetches.fail(edited.id)
        let looked = watching.looks.count
        try await saveElsewhere(climbing: 500, on: 1, in: stage)
        // The save's look, the failed pass's, and the retry pass's.
        await settleDelegateHop(until: "the save's pass and the one it asked for both failed, and looked") {
            watching.fetches.failures(of: edited.id) == 2 && watching.looks.count == looked + 3
        }
        try await saveElsewhere(climbing: 400, on: 2, in: stage)
        await settleDelegateHop(until: "the other new line is published") { stage.has(other, climbing: 400) }
        try await saveElsewhere(climbing: 300, on: 3, in: stage)
        await settleDelegateHop(until: "a line saved afterwards is published") { stage.has(later, climbing: 300) }

        let asked: [[UUID]] = [[edited.id], [edited.id], [edited.id], [other.id], [edited.id], [later.id]]
        #expect(
            watching.measuredSinceFirstPass == asked,
            "only the first failure asks for a pass, and every later wake asks for the hike again"
        )
        #expect(stage.has(edited, climbing: HikeListElevationStage.climb(1)), "the old figures stay")
    }

    @Test("a measurement tells a row that is gone from a fetch that failed")
    func aMeasurementTellsGoneFromFailed() async throws {
        let container = try Fixture.modelContainer()
        let hike = Fixture.hike(in: container.mainContext, route: HikeListElevationStage.line(0, climb: 200))
        try container.mainContext.save()
        let missing = UUID()

        var measured = await HikeListMetrics.measureElevation(for: [hike.id, missing], in: container)

        #expect(measured.figures.map(\.hikeID) == [hike.id])
        #expect(measured.failed.isEmpty, "a row that is gone owes nothing")
        let failing = UUID()
        measured.record(failing) { throw FetchFailure() }
        #expect(measured.failed == [failing])
        #expect(measured.figures.map(\.hikeID) == [hike.id])
    }

    /// Only a line without usable heights needs the figures cached beside
    /// it, to know whether old ones must be cleared.
    @Test("a failed fetch of the cached figures holds back only a line without heights")
    func aFailedFigureFetchHoldsBackOnlyALineWithoutHeights() throws {
        let line = HikeListElevationStage.line(0, climb: 200)
        let measured = HikeListMetrics.RouteInput(hikeID: UUID(), route: line)
        let figures = try HikeListMetrics.measurement(for: measured) { throw FetchFailure() }
        let climb = try #require(figures?.climbMeters)
        #expect(climb.isApproximatelyEqual(to: 200, absoluteTolerance: 0.001))

        let unmeasured = HikeListMetrics.RouteInput(
            hikeID: UUID(),
            route: line.map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        )
        #expect(throws: FetchFailure.self) {
            try HikeListMetrics.measurement(for: unmeasured) { throw FetchFailure() }
        }
        #expect(try HikeListMetrics.measurement(for: unmeasured) { nil } == nil, "nor does it need new figures")
    }
}

/// The list's looks at history, counted as each lands: after it has read
/// history, before the task has its answer.
nonisolated private final class LandedLooks: Sendable {
    private let landed = Mutex(0)

    var count: Int { landed.withLock { $0 } }

    @concurrent
    func look(_ request: StoreHistoryCheck.Request) async -> StoreHistoryCheck.Answer {
        let answer = await StoreHistoryCheck.answer(request)
        landed.withLock { $0 += 1 }
        return answer
    }
}

/// The list's measurements, the hikes each was handed, and the hikes whose
/// fetch it fails: each such measurement answers them as a failed fetch
/// does, and measures the rest for real.
nonisolated private final class FailingFetches: Sendable {
    private let log = Mutex<[[UUID]]>([])
    /// How many more measurements fail each hike.
    private let failing = Mutex<[UUID: Int]>([:])
    private let failed = Mutex<[UUID]>([])

    var calls: [[UUID]] { log.withLock { $0 } }

    /// How many of `hikeID`'s measurements failed its fetch.
    func failures(of hikeID: UUID) -> Int {
        failed.withLock { $0.count { $0 == hikeID } }
    }

    /// Fails `hikeID`'s fetch in its next `times` measurements.
    func fail(_ hikeID: UUID, times: Int = .max) {
        failing.withLock { $0[hikeID] = times }
    }

    @concurrent
    func measure(_ hikeIDs: [UUID], in container: ModelContainer) async -> HikeListMetrics.ElevationMeasurements {
        log.withLock { $0.append(hikeIDs) }
        let failures = failing.withLock { failing in
            Set(hikeIDs.filter { hikeID in
                guard let left = failing[hikeID], left > 0 else { return false }
                failing[hikeID] = left - 1
                return true
            })
        }
        var measured = await HikeListMetrics.measureElevation(
            for: hikeIDs.filter { !failures.contains($0) },
            in: container
        )
        measured.failed.formUnion(failures)
        failed.withLock { $0.append(contentsOf: hikeIDs.filter(failures.contains)) }
        return measured
    }
}
