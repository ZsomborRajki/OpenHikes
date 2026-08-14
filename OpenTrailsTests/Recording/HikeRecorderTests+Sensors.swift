//
//  HikeRecorderTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
@testable import OpenTrails
import OpenTrailsShared
import SwiftData
import Testing

extension HikeRecorderTests {

    @Test("barometric elevation is fused into the saved route")
    func savesFusedElevation() async throws {
        let elevation = StubRecordingElevationSource()
        let recorder = makeRecorder(elevationSource: elevation)
        await recorder.start()
        #expect(elevation.startCount == 1)

        elevation.deliver(0)
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        elevation.deliver(10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        let hike = try savedHike(from: await recorder.stop())

        #expect(elevation.stopCount >= 2)
        #expect(hike.route.count == 2)
        #expect(abs((hike.route[0].elevation ?? 0) - 600) < 0.01)
        #expect(abs((hike.route[1].elevation ?? 0) - 609.8) < 0.01)
    }

    @Test("motion activity preserves a non-pedestrian segment")
    func nonPedestrianMotionIsAcceptedAndSaved() async throws {
        let motion = StubRecordingMotionSource()
        let recorder = makeRecorder(motionSource: motion)
        await recorder.start()
        motion.deliver(.nonPedestrian)
        await settleDelegateHop()

        source.deliver(fix(latitude: 47.63, speed: 1))
        await settleDelegateHop()
        clock.advance(by: 5)
        source.deliver(
            fix(
                latitude: 47.63 + 100 / 111_000,
                speed: 1
            )
        )
        await settleDelegateHop()

        #expect(recorder.stats.pointCount == 2)
        let hike = try savedHike(from: await recorder.stop())
        #expect(hike.route.allSatisfy { $0.motion == .nonPedestrian })
        #expect(motion.startCount == 1)
        #expect(motion.stopCount >= 2)
    }

    @Test("a confident graph match becomes canonical and preserves the GPS trace")
    func savesMatchedAndRawRoutes() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(graph: matchedPathGraph())
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == "Matched Path" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.stats.matchedTrailName == "Matched Path")
        #expect(recorder.trace.tail.allSatisfy { coord in
            abs(coord.longitude - 12.8599) < 0.00001
        })

        // A moved route is reviewed before it is stored; keeping the default
        // choice is what makes the matched line canonical.
        guard case .needsReview = try await recorder.stop() else {
            Issue.record("a moved route should be reviewed before saving")
            return
        }
        let hike = try await recorder.saveReviewedRecording()

        #expect(hike.rawRoute.count == 2)
        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy { coord in
            abs(coord.longitude - 12.8599) < 0.00001
        })
        #expect(hike.rawRoute.allSatisfy { coord in
            abs(coord.longitude - 12.86) < 0.00001
        })
    }

    @Test("live trail name clears when the current leg cannot be matched")
    func liveTrailNameClearsForAnUnmatchedTail() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: liveMatchingGraph()
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == "Live Path" {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.stats.matchedTrailName == "Live Path")

        clock.advance(by: 30)
        source.deliver(fix(latitude: 47.632))
        await settleDelegateHop()
        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.stats.pointCount == 3)
        #expect(recorder.stats.matchedTrailName == nil)
        await recorder.discard()
    }

    @Test("live matching catches up when a fix arrives during graph loading")
    func slowLiveMatchDoesNotStarve() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: liveMatchingGraph(),
                cachedGraphDelay: .milliseconds(50)
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6304))
        await settleDelegateHop()

        for _ in 0..<100 {
            if recorder.stats.matchedTrailName == "Live Path",
               recorder.trace.tail.allSatisfy({ coord in
                   abs(coord.longitude - 12.8599) < 0.00001
               }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.stats.matchedTrailName == "Live Path")
        #expect(recorder.trace.tail.allSatisfy { coord in
            abs(coord.longitude - 12.8599) < 0.00001
        })
        await recorder.discard()
    }

    @Test("ambiguous gaps keep the recording draft until review finishes")
    func ambiguityReviewKeepsDraft() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: ambiguityGraph()
            ),
            sharedStateStore: sharedStore
        )
        await recorder.start()
        let draft = try #require(recorder.currentHike)
        source.deliver(fix(latitude: 47.63, longitude: 12.86))
        await settleDelegateHop()
        clock.advance(by: 720)
        source.deliver(fix(latitude: 47.63, longitude: 12.864))
        await settleDelegateHop()

        let outcome = try await recorder.stop()
        guard case .needsReview = outcome else {
            Issue.record("the sparse fork should require review")
            return
        }

        #expect(recorder.phase == .reviewing)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(draft.isRecording)
        #expect(draft.route.isEmpty)
        let section = try #require(recorder.routeReview?.current)
        #expect(section.kind == .ambiguous)
        #expect(section.alternatives.count >= 2)
        #expect(recorder.trace.reviewSegment.count == 2)
        #expect(FileManager.default.fileExists(atPath: TrackJournal(directory: directory).journalURL.path))
        let sessionID = try #require(
            await sharedStore.savedSnapshots().last?.sessionID
        )
        let lateWidgetFix = SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.631,
            longitude: 12.862,
            timestamp: clock.now.addingTimeInterval(60),
            horizontalAccuracy: 50
        )
        await sharedStore.setPendingFixes([lateWidgetFix])
        recorder.sceneDidBecomeActive()
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.stats.pointCount == 2)
        #expect(!(await sharedStore.removedIDs()).contains(lateWidgetFix.id))

        let alternative = try #require(section.alternatives.first)
        recorder.selectRouteChoice(
            .alternative(alternative.id)
        )
        #expect(recorder.trace.reviewSegment.count > 2)

        let hike = try await recorder.saveReviewedRecording()

        #expect(hike.route.count > 2)
        #expect(hike.rawRoute.count == 2)
        #expect(hike.id == draft.id)
        #expect(!hike.isRecording)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(recorder.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: TrackJournal(directory: directory).journalURL.path))
    }

    @Test("trail graph prefetch follows the recording into new regions")
    func trailGraphPrefetchExtendsWithTheRecording() async {
        let provider = StubTrailGraphProvider(graph: .empty)
        let recorder = makeRecorder(trailGraphProvider: provider)
        await recorder.start()

        source.deliver(fix(latitude: 47.63, longitude: 12.86))
        await settleDelegateHop()
        clock.advance(by: 1000)
        source.deliver(fix(latitude: 47.63, longitude: 12.96))
        await settleDelegateHop()

        for _ in 0..<100 {
            if await provider.prefetches().count == 2 {
                break
            }
            await Task.yield()
        }

        let regions = await provider.prefetches()
        #expect(regions.count == 2)
        #expect(Set(regions).count == 2)
    }

    @Test("trail graph prefetch is cancelled when the recording is discarded")
    func trailGraphPrefetchStopsWithRecording() async {
        let provider = BlockingTrailGraphProvider()
        let recorder = makeRecorder(trailGraphProvider: provider)
        await recorder.start()

        source.deliver(fix(latitude: 47.63, longitude: 12.86))
        await settleDelegateHop()
        for _ in 0..<100 where !(await provider.didStart()) {
            await Task.yield()
        }
        #expect(await provider.didStart())

        await recorder.discard()
        for _ in 0..<100 where !(await provider.wasCancelled()) {
            await Task.yield()
        }

        #expect(await provider.wasCancelled())
        #expect(recorder.trailGraphPrefetchTasks.isEmpty)
        #expect(recorder.trailGraphPrefetchStates.isEmpty)
    }

    @Test("trail graph retry delay exponentiates with jitter and a ceiling")
    func trailGraphRetryPolicyBacksOff() {
        let policy = TrailGraphPrefetchRetryPolicy(
            initialDelay: 10,
            maximumDelay: 100,
            jitterFraction: 0.5
        )

        #expect(policy.delay(afterFailures: 1, jitter: 0) == 10)
        #expect(policy.delay(afterFailures: 1, jitter: 1) == 15)
        #expect(policy.delay(afterFailures: 2, jitter: 0) == 20)
        #expect(policy.delay(afterFailures: 10, jitter: 1) == 100)
    }

    @Test("ordinary trail graph failures wait for per-region backoff")
    func trailGraphFailuresBackOff() async throws {
        let provider = ScriptedTrailGraphProvider(
            failuresBeforeSuccess: 2
        )
        let policy = TrailGraphPrefetchRetryPolicy(
            initialDelay: 30,
            maximumDelay: 120,
            jitterFraction: 0
        )
        let recorder = makeRecorder(
            trailGraphProvider: provider,
            trailGraphRetryPolicy: policy
        )
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )
        let region = try #require(provider.region(containing: coordinate))
        await recorder.start()

        let firstRetryAt = clock.now.addingTimeInterval(30)
        await deliverTrailGraphFix(at: coordinate)
        await waitForTrailGraphPrefetchState(
            .waiting(failures: 1, retryAt: firstRetryAt),
            region: region,
            recorder: recorder
        )
        #expect(await provider.attemptCount() == 1)
        #expect(
            recorder.trailGraphPrefetchStates[region]
                == .waiting(failures: 1, retryAt: firstRetryAt)
        )

        await deliverTrailGraphFix(at: coordinate, after: 20)
        #expect(await provider.attemptCount() == 1)

        let secondRetryAt = firstRetryAt.addingTimeInterval(60)
        await deliverTrailGraphFix(at: coordinate, after: 10)
        await waitForTrailGraphPrefetchState(
            .waiting(failures: 2, retryAt: secondRetryAt),
            region: region,
            recorder: recorder
        )
        #expect(await provider.attemptCount() == 2)
        #expect(
            recorder.trailGraphPrefetchStates[region]
                == .waiting(failures: 2, retryAt: secondRetryAt)
        )

        await deliverTrailGraphFix(at: coordinate, after: 50)
        #expect(await provider.attemptCount() == 2)

        await deliverTrailGraphFix(at: coordinate, after: 10)
        await waitForTrailGraphPrefetchState(
            .loaded,
            region: region,
            recorder: recorder
        )
        #expect(await provider.attemptCount() == 3)
        #expect(recorder.trailGraphPrefetchStates[region] == .loaded)

        clock.advance(by: 1000)
        source.deliver(
            fix(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        await settleDelegateHop()
        #expect(await provider.attemptCount() == 3)
    }

    private func deliverTrailGraphFix(
        at coordinate: CLLocationCoordinate2D,
        after interval: TimeInterval = 0
    ) async {
        clock.advance(by: interval)
        source.deliver(
            fix(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
        await settleDelegateHop()
    }

    private func waitForTrailGraphPrefetchState(
        _ expected: TrailGraphPrefetchState,
        region: TrailGraphRegion,
        recorder: HikeRecorder
    ) async {
        for _ in 0..<100
        where recorder.trailGraphPrefetchStates[region] != expected {
            await Task.yield()
        }
    }

    private actor BlockingTrailGraphProvider: TrailGraphProviding {
        private var started = false
        private var cancelled = false

        nonisolated func region(
            containing coordinate: CLLocationCoordinate2D
        ) -> TrailGraphRegion? {
            TrailGraphRegion(zoom: 12, x: 1, y: 1)
        }

        func prefetch(
            around coordinate: CLLocationCoordinate2D
        ) async throws {
            started = true
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                cancelled = true
                throw CancellationError()
            }
        }

        func cachedGraph(
            covering coordinates: [CLLocationCoordinate2D]
        ) -> TrailGraph? {
            .empty
        }

        func hasCompleteCachedGraph(
            covering coordinates: [CLLocationCoordinate2D]
        ) -> Bool {
            true
        }

        func didStart() -> Bool {
            started
        }

        func wasCancelled() -> Bool {
            cancelled
        }
    }

    @Test("widget anchors are journalled and shared state clears at Stop")
    func widgetFixesAreFoldedIntoTheRecording() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(sharedStateStore: sharedStore)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()

        let snapshots = await sharedStore.savedSnapshots()
        let sessionID = try #require(snapshots.last?.sessionID)
        let widgetFix = SharedRecordingFix(
            sessionID: sessionID,
            latitude: 47.6302,
            longitude: 12.86,
            timestamp: clock.now.addingTimeInterval(20),
            horizontalAccuracy: 60
        )
        await sharedStore.setPendingFixes([widgetFix])
        recorder.sceneDidBecomeActive()
        for _ in 0..<100 {
            if recorder.stats.pointCount == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(recorder.stats.pointCount == 2)
        #expect(recorder.trace.tail.count == 2)

        clock.advance(by: 40)
        source.deliver(fix(latitude: 47.6304))
        await settleDelegateHop()
        let hike = try savedHike(from: await recorder.stop())

        #expect(hike.route.count == 3)
        #expect(await sharedStore.removedIDs().contains(widgetFix.id))
        #expect(
            await sharedStore.clearCalls().contains { call in
                call == sessionID
            }
        )
    }

    @Test("periodic snapshots do not force extra WidgetKit reloads")
    func periodicSnapshotsDoNotForceReloads() async throws {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(sharedStateStore: sharedStore)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        clock.advance(by: 15 * 60)
        source.deliver(fix(latitude: 47.6302))
        await settleDelegateHop()

        for _ in 0..<100 {
            if await sharedStore.savedSnapshots().count >= 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await sharedStore.widgetReloadFlags().last == false)
    }
}
