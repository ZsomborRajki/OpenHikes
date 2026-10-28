//
//  PinnedTrailLivePublicationTests.swift
//  OpenHikesTests
//
//  A launch can still be building a pinned trail's static snapshot when the
//  live feed publishes its first fix or a pause. The pinned and selected
//  widgets must then read the same live progress, not whichever build happened
//  to finish last (#1160). Hold the actual static builder at its publication
//  boundary and drive the same SnapshotWriter the live tracker uses.
//
//  Every store operation inherits SharedStore's task-local temporary root;
//  the injected map boundary never reaches MapKit or the renderer singleton.
//

import Dispatch
import Foundation
@testable import OpenHikes
import OpenHikesData
@testable import OpenHikesShared
import SwiftData
import Synchronization
import Testing

@Suite("Pinned trail live publication", .timeLimit(.minutes(1)))
struct PinnedTrailLivePublicationTests {
    private let input: HikeRouteInput
    private let other: HikeRouteInput

    init() throws {
        let context = ModelContext(try Fixture.modelContainer())
        input = HikeRouteInput(hike: Fixture.hike(in: context, title: "Walked trail"))
        other = HikeRouteInput(hike: Fixture.hike(in: context, title: "Other pinned trail"))
    }

    @Test("a delayed static build preserves a newer live fix and walk", arguments: [false, true])
    func delayedBuildPreservesLiveProgress(paused: Bool) async throws {
        try await withStore {
            let writer = Self.writer()
            let initial = try await Self.snapshot(for: other)
            #expect(await writer.save(initial, ifCurrent: 0))
            let gate = TestGate()
            defer { gate.open() }
            let maps = MapLog()
            let publication = Self.publication(input, gate: gate, maps: maps)
            let staticPublish = Task {
                await SharedHikeCatalogPublisher.publishTrail(input.hikeID, writer: writer, publication: publication)
            }
            await settleDelegateHop(until: "the static snapshot is built and held before publication") {
                gate.isHolding
            }
            let live = await writer.applyLiveFix(
                Self.fix(for: input),
                input: input,
                elevation: RouteProfile(route: input.route).elevation,
                walk: Self.walk(paused: false),
                ifCurrent: 0
            )
            if paused {
                #expect(await writer.applyWalk(Self.walk(paused: true), hikeID: input.hikeID, ifCurrent: 0) != nil)
            }
            gate.open()
            await staticPublish.value

            let written = try #require(live)
            let selected = try #require(SharedStore.load())
            let pinned = try #require(SharedStore.loadTrailSnapshot(for: input.hikeID))
            #expect(pinned == selected, "both widget configurations must read the same complete live payload")
            #expect(pinned.liveFix == written.snapshot.liveFix)
            #expect(pinned.walk == Self.walk(paused: paused))
            #expect(pinned.progressFraction == selected.progressFraction)
            #expect(await maps.hikeIDs == [input.hikeID])
        }
    }

    @Test("a different pinned trail still publishes its static route and map")
    func otherPinnedTrailStaysStatic() async throws {
        try await withStore {
            let writer = Self.writer()
            var live = try await Self.snapshot(for: input)
            live.liveFix = Self.fix(for: input)
            live.walk = Self.walk(paused: false)
            #expect(await writer.save(live, ifCurrent: 0))
            let maps = MapLog()
            await SharedHikeCatalogPublisher.publishTrail(
                other.hikeID,
                writer: writer,
                publication: Self.publication(other, maps: maps)
            )

            let pinned = try #require(SharedStore.loadTrailSnapshot(for: other.hikeID))
            #expect(pinned.hikeID == other.hikeID)
            #expect(pinned.polyline.count == other.route.count)
            #expect(pinned.liveFix == nil)
            #expect(pinned.walk == nil)
            #expect(SharedStore.load() == live)
            #expect(await maps.hikeIDs == [other.hikeID])
        }
    }

    @Test("ownership is checked after building, so a former selection can become static")
    func ownershipCanMoveDuringTheBuild() async throws {
        try await withStore {
            let writer = Self.writer()
            var former = try await Self.snapshot(for: input)
            former.liveFix = Self.fix(for: input)
            former.walk = Self.walk(paused: false)
            #expect(await writer.save(former, ifCurrent: 0))
            let selected = try await Self.snapshot(for: other)
            let gate = TestGate()
            defer { gate.open() }
            let publication = Self.publication(input, gate: gate)
            let staticPublish = Task {
                await SharedHikeCatalogPublisher.publishTrail(input.hikeID, writer: writer, publication: publication)
            }
            await settleDelegateHop(until: "the former selection's static build is held") { gate.isHolding }
            #expect(await writer.save(selected, ifCurrent: 0))
            gate.open()
            await staticPublish.value

            let pinned = try #require(SharedStore.loadTrailSnapshot(for: input.hikeID))
            #expect(pinned.liveFix == nil)
            #expect(pinned.walk == nil)
            #expect(SharedStore.load() == selected)
        }
    }

    @Test("static publication cannot enter between the live mirror and selected-file writes")
    func liveMirrorAndSelectionCommitTogether() async throws {
        try await withStore {
            let writer = Self.writer()
            #expect(await writer.save(try await Self.snapshot(for: other), ifCurrent: 0))
            var live = try await Self.snapshot(for: input)
            live.liveFix = Self.fix(for: input)
            live.walk = Self.walk(paused: true)
            let root = try #require(SharedStore.appGroupContainerURL())
            let mirror = MirrorGate(root: root, hikeID: input.hikeID)
            defer { mirror.open() }
            let liveSave = Task {
                await SharedStore.$containerOverride.withValue(SharedStore.ContainerOverride { mirror.resolve() }) {
                    await writer.save(live, ifCurrent: 0)
                }
            }
            await settleDelegateHop(until: "the live mirror is written before the selected file changes") {
                mirror.isHolding
            }
            let built = Mutex(false)
            let publication = Self.publication(input, didBuild: {
                #expect(
                    Thread.isMainThread,
                    "the static caller must keep the main-actor turn through its commit attempt"
                )
                built.withLock { $0 = true }
            })
            let staticPublish = Task { @MainActor in
                await SharedHikeCatalogPublisher.publishTrail(input.hikeID, writer: writer, publication: publication)
            }
            // The caller stays on the main actor through its first commit
            // attempt. Observing this flag in a later turn means an ungated
            // read/check/write has already run, or the shared actor is queued.
            await settleDelegateHop(until: "the static build has returned to its publication attempt") {
                built.withLock { $0 }
            }
            mirror.open()
            #expect(await liveSave.value)
            await staticPublish.value

            #expect(SharedStore.load() == live)
            #expect(SharedStore.loadTrailSnapshot(for: input.hikeID) == live)
        }
    }

    private static func writer() -> BackgroundTrailTracker.SnapshotWriter {
        BackgroundTrailTracker.SnapshotWriter(
            generation: BackgroundTrailTracker.SelectionGeneration(),
            widgetReload: TrailWidgetReload(reload: { /* The suite never requests a timeline reload. */ })
        )
    }

    private static func publication(
        _ input: HikeRouteInput,
        gate: TestGate? = nil,
        maps: MapLog = MapLog(),
        didBuild: @escaping @Sendable () -> Void = { /* Most tests hold the build through TestGate instead. */ }
    ) -> SharedHikeCatalogPublisher.PinnedTrailPublication {
        SharedHikeCatalogPublisher.PinnedTrailPublication(
            build: { _ in
                let snapshot = await BackgroundTrailTracker.buildSnapshotOffMain(from: input, liveFix: nil)
                if let gate { await gate.wait() }
                didBuild()
                return snapshot
            },
            refreshBasemap: { hikeID, _ in await maps.record(hikeID) }
        )
    }

    private static func snapshot(for input: HikeRouteInput) async throws -> SharedTrailSnapshot {
        try #require(await BackgroundTrailTracker.buildSnapshotOffMain(from: input, liveFix: nil))
    }

    private static func fix(for input: HikeRouteInput) -> SharedTrailSnapshot.LiveFix {
        let point = input.route[input.route.count / 2]
        return SharedTrailSnapshot.LiveFix(
            coordinate: .init(latitude: point.latitude, longitude: point.longitude),
            distanceAlongRouteMeters: input.totalDistanceMeters / 2,
            offRouteMeters: 0,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private static func walk(paused: Bool) -> SharedTrailSnapshot.Walk {
        SharedTrailSnapshot.Walk(
            state: paused ? .paused : .active,
            coveredFraction: 0.5,
            furthestDistanceMeters: 500,
            activeSeconds: 300,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func withStore(_ body: () async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await SharedStore.$containerOverride.withValue(SharedStore.ContainerOverride { root }, operation: body)
    }

    private actor MapLog {
        private(set) var hikeIDs: [UUID] = []

        func record(_ hikeID: UUID) { hikeIDs.append(hikeID) }
    }

    /// Holds the real selected save at its existing mirror-first boundary,
    /// using the container resolver rather than replacing either store write.
    /// Only the live task binds this resolver; the launch uses the same root
    /// through the enclosing test's ordinary binding.
    nonisolated private final class MirrorGate: Sendable {
        private struct State {
            var holding = false
            var opened = false
        }

        private let state = Mutex(State())
        private let release = DispatchSemaphore(value: 0)
        private let root: URL
        private let hikeID: UUID

        init(root: URL, hikeID: UUID) {
            self.root = root
            self.hikeID = hikeID
        }

        var isHolding: Bool { state.withLock { $0.holding } }

        func resolve() -> URL? {
            let mirrored = snapshot(at: root.appendingPathComponent("trail-snapshots/\(hikeID.uuidString).json"))
            let selected = snapshot(at: root.appendingPathComponent("trail-snapshot.json"))
            let shouldHold = state.withLock { state in
                guard !state.opened, !state.holding, mirrored?.liveFix != nil, selected?.hikeID != hikeID
                else { return false }
                state.holding = true
                return true
            }
            if shouldHold { release.wait() }
            return root
        }

        func open() {
            state.withLock { $0.opened = true }
            release.signal()
        }

        private func snapshot(at url: URL) -> SharedTrailSnapshot? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(SharedTrailSnapshot.self, from: data)
        }
    }
}
