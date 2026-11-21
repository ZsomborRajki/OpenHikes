//
//  HikeRecorderTests.swift
//  OpenHikesTests
//
//  `source.deliver(…)`, `elevation.deliver(…)` and `motion.deliver(…)` need no
//  settle: the recorder's `nonisolated` callbacks reach main-actor state
//  through `onMainActor`, which runs its body synchronously when the caller is
//  already on the main actor — and a main-actor-isolated test always is. That
//  also fixes their order against each other, which is what lets a barometric
//  reading below be delivered immediately before the fix it belongs to. What
//  the callbacks queue for later — live matching, the journal, the widget
//  snapshot, a trail-graph prefetch — is waited for by name.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
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
        clock.advance(by: 10)
        elevation.deliver(10)
        source.deliver(fix(latitude: 47.6302))

        let hike = try await recorder.stop()

        #expect(elevation.stopCount >= 2)
        #expect(hike.route.count == 2)
        #expect((hike.route[0].elevation ?? 0).isApproximatelyEqual(to: 600, absoluteTolerance: 0.01))
        #expect((hike.route[1].elevation ?? 0).isApproximatelyEqual(to: 609.8, absoluteTolerance: 0.01))
    }

    @Test("motion activity preserves a non-pedestrian segment")
    func nonPedestrianMotionIsAcceptedAndSaved() async throws {
        let motion = StubRecordingMotionSource()
        let recorder = makeRecorder(motionSource: motion)
        await recorder.start()
        motion.deliver(.nonPedestrian)

        source.deliver(fix(latitude: 47.63, speed: 1))
        clock.advance(by: 5)
        source.deliver(
            fix(
                latitude: 47.63 + 100 / 111_000,
                speed: 1
            )
        )

        #expect(recorder.stats.pointCount == 2)
        let hike = try await recorder.stop()
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
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        await settleDelegateHop(until: "the live match to name the trail") {
            recorder.stats.currentTrail?.name == "Matched Path"
        }
        #expect(recorder.stats.currentTrail?.name == "Matched Path")
        #expect(recorder.trace.tail.allSatisfy { coord in
            coord.longitude.isApproximatelyEqual(to: 12.8599, absoluteTolerance: 0.00001)
        })

        // A moved route is saved at once, on the trail: the confident
        // match is the stretch's default — see ``RouteAssembly``.
        let hike = try await recorder.stop()

        #expect(hike.rawRoute.count == 2)
        #expect(hike.route.count == 2)
        #expect(hike.route.allSatisfy { coord in
            coord.longitude.isApproximatelyEqual(to: 12.8599, absoluteTolerance: 0.00001)
        })
        #expect(hike.rawRoute.allSatisfy { coord in
            coord.longitude.isApproximatelyEqual(to: 12.86, absoluteTolerance: 0.00001)
        })
    }

    @Test("live trail name clears when the current leg cannot be matched")
    func liveTrailNameClearsForAnUnmatchedTail() async {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: liveMatchingGraph()
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        // `currentTrail` is written after the matched geometry it describes,
        // so naming the trail also settles the trace behind it.
        await settleDelegateHop(until: "the live match to name the trail") {
            recorder.stats.currentTrail?.name == "Live Path"
        }
        #expect(recorder.stats.currentTrail?.name == "Live Path")

        clock.advance(by: 30)
        source.deliver(fix(latitude: 47.632))
        await settleDelegateHop(until: "the unmatchable tail to clear the trail name") {
            recorder.stats.currentTrail == nil
        }

        #expect(recorder.stats.pointCount == 3)
        #expect(recorder.stats.currentTrail == nil)
        await recorder.discard()
    }

    @Test("live matching catches up when a fix arrives during graph loading")
    func slowLiveMatchDoesNotStarve() async {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: liveMatchingGraph(),
                cachedGraphDelay: .milliseconds(50)
            )
        )
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6304))

        await settleDelegateHop(until: "the delayed match to catch up with every fix") {
            recorder.stats.currentTrail?.name == "Live Path"
                && recorder.trace.tail.allSatisfy { coord in
                    coord.longitude.isApproximatelyEqual(to: 12.8599, absoluteTolerance: 0.00001)
                }
        }

        #expect(recorder.stats.currentTrail?.name == "Live Path")
        #expect(recorder.trace.tail.allSatisfy { coord in
            coord.longitude.isApproximatelyEqual(to: 12.8599, absoluteTolerance: 0.00001)
        })
        await recorder.discard()
    }

    @Test("an ambiguous gap is saved as it was recorded, with its other routes kept to choose from")
    func anAmbiguousGapIsSavedWithItsRoutes() async throws {
        let recorder = makeRecorder(
            trailGraphProvider: StubTrailGraphProvider(
                graph: ambiguityGraph()
            )
        )
        await recorder.start()
        let draft = try #require(recorder.currentHike)
        source.deliver(fix(latitude: 47.63, longitude: 12.86))
        clock.advance(by: 720)
        source.deliver(fix(latitude: 47.63, longitude: 12.864))

        let hike = try await recorder.stop()

        #expect(recorder.phase == .idle)
        #expect(hike.id == draft.id)
        #expect(!hike.isRecording)
        #expect(hike.route.count == 2, "the measurement, until somebody says which way it went")
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(!FileManager.default.fileExists(atPath: TrackJournal(directory: directory).journalURL.path))

        var assembly = try #require(hike.routeEdit?.assembly)
        #expect(assembly.uncheckedCount == 1)
        let check = try #require(assembly.checks.first)
        #expect(check.kind == .ambiguous)
        #expect(check.choice == .gps)
        #expect(check.alternatives.count >= 2)
        #expect(assembly.line(saved: hike.route, raw: hike.rawRoute).route == hike.route)

        let alternative = try #require(check.alternatives.first)
        assembly.checks[0].choice = .alternative(alternative.id)
        let chosen = assembly.line(saved: hike.route, raw: hike.rawRoute).route
        #expect(chosen.count > 2, "the route the matcher offered, kept with the hike")
        #expect(chosen.first?.latitude == hike.route.first?.latitude)
        #expect(chosen.last?.longitude == hike.route.last?.longitude)
    }

    @Test("trail graph prefetch follows the recording into new regions")
    func trailGraphPrefetchExtendsWithTheRecording() async {
        let provider = StubTrailGraphProvider(graph: .empty)
        let recorder = makeRecorder(trailGraphProvider: provider)
        await recorder.start()

        let first = fix(latitude: 47.63, longitude: 12.86)
        source.deliver(first)
        // Far enough to be a different region, slow enough that
        // ``RecordingFixPolicy`` accepts it. The clock has to move before the
        // fix is built: ``fix(latitude:longitude:accuracy:speed:)`` stamps it
        // with ``clock/now``, and a displacement in no time is rejected.
        clock.advance(by: 4000)
        let second = fix(latitude: 47.63, longitude: 12.96)
        source.deliver(second)

        // Each fix also seeds its eight neighbours (see
        // ``HikeRecorder/prefetchNeighboringTrailGraphRegions(around:)``), so
        // the assertion is that the two regions walked through were fetched —
        // not that nothing else was.
        let walked = [first, second].compactMap { location in
            provider.region(containing: location.coordinate)
        }
        let regions = await settle(provider) { fetched in
            walked.allSatisfy(fetched.contains)
        }

        #expect(walked.count == 2)
        #expect(walked.allSatisfy(regions.contains))
    }

    @Test("speculative neighbour prefetch is skipped when the policy denies it")
    func neighborPrefetchRespectsNetworkPolicy() async throws {
        let provider = StubTrailGraphProvider(graph: .empty)
        // Bound to a constant rather than written inline: `makeRecorder`
        // takes further closures after this one, so a trailing closure
        // would land on the wrong parameter.
        let denySpeculative: @Sendable (TileFetchPurpose) -> TileNetworkDecision = { purpose in
            purpose == .speculative ? .denied("cellular-speculative") : .allowed
        }
        let recorder = makeRecorder(
            trailGraphProvider: provider,
            trailGraphNetworkDecision: denySpeculative
        )
        await recorder.start()

        let only = fix(latitude: 47.63, longitude: 12.86)
        source.deliver(only)

        let region = try #require(provider.region(containing: only.coordinate))
        // `.loaded` is written immediately before the neighbour sweep is
        // decided, so reaching it proves the fix was carried all the way to
        // the decision — the provider's own prefetch log reaches the region
        // one step earlier than that, while the sweep is still to come.
        await waitForTrailGraphPrefetchState(
            .loaded,
            region: region,
            recorder: recorder
        )
        // And `prefetchNeighboringTrailGraphRegions` assigns its task
        // synchronously, so a sweep the policy failed to deny is waited
        // through here rather than raced against.
        await recorder.neighborPrefetchTask?.value

        #expect(Set(await provider.prefetches()) == [region])
    }

    /// Waits for a provider's prefetch log to satisfy `condition`, then returns
    /// it. Real sleeps rather than `Task.yield()`: the work being waited for
    /// runs on an actor off the main one, and yielding the main actor buys an
    /// amount of that progress that depends on machine load.
    private func settle(
        _ provider: StubTrailGraphProvider,
        until condition: (Set<TrailGraphRegion>) -> Bool
    ) async -> Set<TrailGraphRegion> {
        let deadline = ContinuousClock.now + .seconds(5)
        var fetched = Set(await provider.prefetches())
        while !condition(fetched), ContinuousClock.now < deadline {
            guard await settlePollTick() else { break }
            fetched = Set(await provider.prefetches())
        }
        return fetched
    }

    /// The same wait for the widget snapshots a recording publishes. Also not
    /// a ``settleDelegateHop(until:sourceLocation:condition:)``: reading them
    /// means awaiting an actor, and a settle condition is synchronous.
    private func settle(
        _ store: StubRecordingSharedStateStore,
        until condition: ([SharedRecordingSnapshot]) -> Bool
    ) async -> [SharedRecordingSnapshot] {
        let deadline = ContinuousClock.now + .seconds(5)
        var snapshots = await store.savedSnapshots()
        while !condition(snapshots), ContinuousClock.now < deadline {
            guard await settlePollTick() else { break }
            snapshots = await store.savedSnapshots()
        }
        return snapshots
    }

    /// The general form, for a flag that only an `await` can read. The caller
    /// still asserts, so a lapsed deadline is reported as the expectation it
    /// was waiting for rather than as a bare timeout.
    private func settle(untilTrue condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            guard await settlePollTick() else { break }
        }
    }

    @Test("trail graph prefetch is cancelled when the recording is discarded")
    func trailGraphPrefetchStopsWithRecording() async {
        let provider = BlockingTrailGraphProvider()
        let recorder = makeRecorder(trailGraphProvider: provider)
        await recorder.start()

        source.deliver(fix(latitude: 47.63, longitude: 12.86))
        await settle { await provider.didStart() }
        #expect(await provider.didStart())

        await recorder.discard()
        await settle { await provider.wasCancelled() }

        #expect(await provider.wasCancelled())
        #expect(recorder.trailGraphPrefetchTasks.isEmpty)
        #expect(recorder.trailGraphPrefetchStates.isEmpty)
    }

    @Test("a provider reporting cancellation does not strand its region")
    func selfCancellingPrefetchDoesNotStrandRegion() async throws {
        let provider = CancellingTrailGraphProvider()
        let recorder = makeRecorder(trailGraphProvider: provider)
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )
        let region = try #require(provider.region(containing: coordinate))
        await recorder.start()

        deliverTrailGraphFix(at: coordinate)
        await settle { await provider.attemptCount() == 1 }
        await settleDelegateHop(
            until: "the cancelled prefetch to release its region"
        ) {
            recorder.trailGraphPrefetchStates[region] == nil
        }

        // Stranded in `.fetching`, the region reads as already-handled, so no
        // later fix ever retries it and it silently never gets a graph.
        #expect(recorder.trailGraphPrefetchStates[region] == nil)

        deliverTrailGraphFix(at: coordinate, after: 10)
        await settle { await provider.attemptCount() == 2 }
        #expect(await provider.attemptCount() == 2)
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
        deliverTrailGraphFix(at: coordinate)
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

        deliverTrailGraphFix(at: coordinate, after: 20)
        #expect(await provider.attemptCount() == 1)

        let secondRetryAt = firstRetryAt.addingTimeInterval(60)
        deliverTrailGraphFix(at: coordinate, after: 10)
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

        deliverTrailGraphFix(at: coordinate, after: 50)
        #expect(await provider.attemptCount() == 2)

        deliverTrailGraphFix(at: coordinate, after: 10)
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
        // Nothing to wait for: a region that is already `.loaded` is refused
        // by `prefetchTrailGraphIfNeeded` while the fix is still on the stack.
        #expect(await provider.attemptCount() == 3)
    }

    private func deliverTrailGraphFix(
        at coordinate: CLLocationCoordinate2D,
        after interval: TimeInterval = 0
    ) {
        clock.advance(by: interval)
        source.deliver(
            fix(latitude: coordinate.latitude, longitude: coordinate.longitude)
        )
    }

    private func waitForTrailGraphPrefetchState(
        _ expected: TrailGraphPrefetchState,
        region: TrailGraphRegion,
        recorder: HikeRecorder,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await settleDelegateHop(
            until: Comment(
                rawValue: "the prefetch state to reach \(String(describing: expected))"
            ),
            sourceLocation: sourceLocation
        ) {
            recorder.trailGraphPrefetchStates[region] == expected
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

        let snapshots = await settle(sharedStore) { !$0.isEmpty }
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
        await settleDelegateHop(until: "the widget's anchor to be merged into the recording") {
            recorder.stats.pointCount == 2
        }

        #expect(recorder.stats.pointCount == 2)
        #expect(recorder.trace.tail.count == 2)

        clock.advance(by: 40)
        source.deliver(fix(latitude: 47.6304))
        let hike = try await recorder.stop()

        #expect(hike.route.count == 3)
        #expect(await sharedStore.removedIDs().contains(widgetFix.id))
        #expect(
            await sharedStore.clearCalls().contains { call in
                call == sessionID
            }
        )
    }

    @Test("periodic snapshots do not force extra WidgetKit reloads")
    func periodicSnapshotsDoNotForceReloads() async {
        let sharedStore = StubRecordingSharedStateStore()
        let recorder = makeRecorder(sharedStateStore: sharedStore)
        await recorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 15 * 60)
        source.deliver(fix(latitude: 47.6302))

        // Three: the session's own snapshot, the first fix's forced one, and
        // the interval-driven one the second fix is far enough away to earn.
        _ = await settle(sharedStore) { $0.count >= 3 }

        #expect(await sharedStore.widgetReloadFlags().last == false)
    }
}
