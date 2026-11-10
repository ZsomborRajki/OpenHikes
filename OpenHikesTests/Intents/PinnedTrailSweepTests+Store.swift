//
//  PinnedTrailSweepTests+Store.swift
//  OpenHikesTests
//
//  The same sweep end to end, from a pinned hike's read to the files a
//  widget draws: the real read of an in-memory store, the live feed's own
//  writer and the App Group's snapshot files, under `SharedStore`'s
//  task-local temporary root. Only the map lane is a log, because a pinned
//  trail's map is a MapKit render and its prune belongs to the renderer
//  singleton.
//
//  A hike deleted on another device is a row this store never held: made in
//  a container of its own, with its old snapshot left on disk as an earlier
//  launch would have left it (#1378).
//

import Foundation
@testable import OpenHikes
import OpenHikesData
@testable import OpenHikesShared
import SwiftData
import Testing

extension PinnedTrailSweepTests {
    /// What a store that cannot answer throws.
    nonisolated struct StoreRefusal: Error {}

    @Test("a pinned hike deleted elsewhere loses its snapshot, and one still here keeps its own")
    func aHikeDeletedElsewhereLosesItsSnapshot() async throws {
        let here = try Fixture.modelContainer()
        let present = try Self.savedHike(in: here, title: "Still here")
        let deleted = try Self.hikeElsewhere(title: "Deleted on another device")
        let log = WriteLog()
        try await withStore {
            SharedStore.saveTrailSnapshot(try await Self.snapshot(of: present))
            SharedStore.saveTrailSnapshot(try await Self.snapshot(of: deleted))

            await SharedHikeCatalogPublisher.publishPinnedTrails(
                Self.storeSweep(
                    pinning: [present.hikeID, deleted.hikeID],
                    in: here,
                    writer: Self.writer(log),
                    into: log
                )
            )

            #expect(SharedStore.loadTrailSnapshot(for: deleted.hikeID) == nil)
            #expect(SharedStore.loadTrailSnapshot(for: present.hikeID)?.title == "Still here")
            #expect(
                log.recorded == Writes(published: [present.hikeID], keptBasemaps: [[present.hikeID]], reloads: 1)
            )
        }
    }

    /// The other half of the distinction: a store that could not answer is
    /// not a deletion, and the widget keeps drawing the trail it had.
    @Test("a pinned hike whose read failed keeps its snapshot and map, and nothing redraws")
    func aFailedReadKeepsTheSnapshot() async throws {
        let here = try Fixture.modelContainer()
        let hike = try Self.savedHike(in: here, title: "Unreadable for now")
        let log = WriteLog()
        try await withStore {
            let old = try await Self.snapshot(of: hike)
            SharedStore.saveTrailSnapshot(old)

            await SharedHikeCatalogPublisher.publishPinnedTrails(
                Self.storeSweep(
                    pinning: [hike.hikeID],
                    in: here,
                    writer: Self.writer(log),
                    fetch: { _, _ in throw StoreRefusal() },
                    into: log
                )
            )

            #expect(SharedStore.loadTrailSnapshot(for: hike.hikeID) == old)
            #expect(log.recorded == Writes(keptBasemaps: [[hike.hikeID]]))
        }
    }

    /// A launch whose store would not open runs on an empty in-memory one,
    /// which finds every pin gone without failing. That is no answer about
    /// the store the pins were made from, and a map deleted on it comes back
    /// only with a render, on a launch that has the network.
    @Test("a launch on the in-memory fallback keeps every pinned trail's snapshot and map")
    func theFallbackStoreKeepsEveryPin() async throws {
        let fallback = try Fixture.modelContainer()
        let pinned = try Self.hikeElsewhere(title: "In the store that would not open")
        let log = WriteLog()
        try await withStore {
            let old = try await Self.snapshot(of: pinned)
            SharedStore.saveTrailSnapshot(old)

            await SharedHikeCatalogPublisher.publishPinnedTrails(
                Self.storeSweep(
                    pinning: [pinned.hikeID],
                    in: fallback,
                    writer: Self.writer(log),
                    into: log,
                    storageIsDurable: false
                )
            )

            #expect(SharedStore.loadTrailSnapshot(for: pinned.hikeID) == old)
            #expect(log.recorded == Writes(keptBasemaps: [[pinned.hikeID]]))
        }
    }

    /// The live feed's trail is the feed's, as #1160 made its static route:
    /// its next write would put the mirror back, so a prune in between only
    /// blanks the pinned widget for the length of a fix.
    @Test("a hike that is gone keeps its snapshot while the live feed holds it")
    func theLiveFeedKeepsItsOwnTrail() async throws {
        let here = try Fixture.modelContainer()
        let deleted = try Self.hikeElsewhere(title: "Followed, then deleted elsewhere")
        let log = WriteLog()
        try await withStore {
            let writer = Self.writer(log)
            let live = try await Self.snapshot(of: deleted)
            #expect(await writer.save(live, ifCurrent: 0))

            await SharedHikeCatalogPublisher.publishPinnedTrails(
                Self.storeSweep(pinning: [deleted.hikeID], in: here, writer: writer, into: log)
            )

            #expect(SharedStore.loadTrailSnapshot(for: deleted.hikeID) == live)
            #expect(SharedStore.load() == live)
            #expect(log.recorded == Writes(keptBasemaps: [[deleted.hikeID]]))
        }
    }

    /// The takeover rule survives: the files still go, since nothing should
    /// draw them, but the redraw is the trail feed's and a recording owns
    /// the widget. Its own end redraws unconditionally, and finds them gone.
    @Test("while a recording owns the widget, a gone pin's snapshot goes without a redraw")
    func aRecordingKeepsTheWidget() async throws {
        let here = try Fixture.modelContainer()
        let deleted = try Self.hikeElsewhere(title: "Deleted while recording")
        let log = WriteLog()
        try await withStore {
            let recording = Self.recording(along: deleted)
            try SharedStore.saveRecording(recording)
            SharedStore.saveTrailSnapshot(try await Self.snapshot(of: deleted))

            await SharedHikeCatalogPublisher.publishPinnedTrails(
                Self.storeSweep(pinning: [deleted.hikeID], in: here, writer: Self.writer(log), into: log)
            )

            #expect(SharedStore.loadTrailSnapshot(for: deleted.hikeID) == nil)
            #expect(SharedStore.loadRecording()?.sessionID == recording.sessionID)
            #expect(log.recorded == Writes(keptBasemaps: [[]]))
        }
    }

    /// The live sweep's own parts, but for the map lane, which logs; and the
    /// live feed's writer, whose redraws the log counts.
    private static func storeSweep(
        pinning pinned: Set<UUID>,
        in container: ModelContainer,
        writer: BackgroundTrailTracker.SnapshotWriter,
        fetch: @escaping @Sendable (ModelContext, UUID) throws -> Hike? = SharedHikeCatalogPublisher.fetchHike,
        into log: WriteLog,
        storageIsDurable: Bool = true
    ) -> SharedHikeCatalogPublisher.PinnedTrailSweep {
        let publication = SharedHikeCatalogPublisher.PinnedTrailPublication(
            build: { hikeID in
                await SharedHikeCatalogPublisher.PinnedTrailPublication.liveBuild(
                    of: hikeID,
                    in: container,
                    storageIsDurable: storageIsDurable,
                    fetch: fetch
                )
            },
            refreshBasemap: { hikeID, _ in log.record { $0.published.append(hikeID) } }
        )
        return SharedHikeCatalogPublisher.PinnedTrailSweep(
            pinnedTrails: { .known(pinned) },
            selectedHikeIDs: { [] },
            publishTrail: { hikeID in
                await SharedHikeCatalogPublisher.publishTrail(hikeID, writer: writer, publication: publication)
            },
            pruneTrailSnapshots: { SharedStore.pruneTrailSnapshots(keeping: $0) },
            pruneBasemaps: { kept in log.record { $0.keptBasemaps.append(kept) } },
            reloadWidgets: { await writer.reloadWidget() }
        )
    }

    private static func writer(_ log: WriteLog) -> BackgroundTrailTracker.SnapshotWriter {
        BackgroundTrailTracker.SnapshotWriter(
            generation: BackgroundTrailTracker.SelectionGeneration(),
            widgetReload: TrailWidgetReload(reload: { log.record { $0.reloads += 1 } })
        )
    }

    /// A hike in `container`, saved so the sweep's own context can read it.
    private static func savedHike(in container: ModelContainer, title: String) throws -> HikeRouteInput {
        let context = ModelContext(container)
        let hike = Fixture.hike(in: context, title: title)
        try context.save()
        return HikeRouteInput(hike: hike)
    }

    /// A hike this device's store has never held: what a row deleted on
    /// another device leaves of itself here.
    private static func hikeElsewhere(title: String) throws -> HikeRouteInput {
        HikeRouteInput(hike: Fixture.hike(in: try Fixture.modelContext(), title: title))
    }

    private static func snapshot(of input: HikeRouteInput) async throws -> SharedTrailSnapshot {
        try #require(await BackgroundTrailTracker.buildSnapshotOffMain(from: input, liveFix: nil))
    }

    /// A recording in progress, which owns the widget whatever is pinned.
    private static func recording(along input: HikeRouteInput) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: .now,
            distanceMeters: input.totalDistanceMeters,
            pointCount: input.route.count,
            polyline: input.route.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            isCapturingFixes: true
        )
    }

    private func withStore(_ body: () async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-sweep-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await SharedStore.$containerOverride.withValue(SharedStore.ContainerOverride { root }, operation: body)
    }
}
