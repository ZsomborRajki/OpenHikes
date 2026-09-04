//
//  StoredTileDeletionTests.swift
//  OpenHikesTests
//
//  The Delete button on a hike's "Offline tiles" row, and the order it does
//  its two irreversible things in.
//
//  Deleting a saved map is a manifest change and a pile of file removals, and
//  only one order of the two survives being interrupted. The screen used to
//  empty the manifests in the model context, never save them, and start
//  unlinking tiles in the same breath — so a refused save, or a process that
//  stopped in that window, brought the manifest back claiming files that were
//  already gone. Nothing detects that state: a claim with no file behind it
//  looks exactly like a claim that is satisfied, so every sweep reads it as
//  intentional, the storage row goes on counting bytes that are not there,
//  and nothing re-downloads the map. The walker finds out where there is no
//  signal.
//
//  So these ask two things of ``StoredTileDeletion``. What is true at the
//  moment the commit lands — the manifests already empty, every planned tile
//  still on disk — and what is true when the store says no: the manifests,
//  the tiles, the auto-save arming and a download still in flight all exactly
//  as the walker left them.
//
//  `HikeDeletionFailureTests` owns the other refusal on this path, the one
//  where a *claim* cannot be read; `OfflineStorageAccountingTests` owns which
//  tiles a plan frees. What is here is the ordering around the save.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The failure a `ModelContext` cannot be made to produce on demand — a fetch
/// against a schema it does not know returns an empty result rather than an
/// error — which is why the library fetch is a closure.
private struct LibraryReadFailure: Error {}

@Suite("Deleting a hike's saved map")
struct StoredTileDeletionTests {
    /// The tile both hikes claim, and the one only the deleting hike does.
    /// Both live in the durable directory, which is where the stakes are:
    /// browsing residue is re-fetched for free, a tile in there was saved on
    /// purpose for a walk with no signal.
    private static let sharedKey = "osm/14/8723/5685@2.0"
    private static let exclusiveKey = "osm/14/8724/5685@2.0"
    /// A tile inside the ridge fixture's own corridor, so the auto-save store
    /// claims it the way it does in the app.
    nonisolated private static let corridorKey = "osm/14/2638/6357@2.0"
    nonisolated private static let corridorTile = (z: 14, x: 2638, y: 6357)

    /// Stadia for its download policy alone — the one source whose terms
    /// permit a bulk download — with a template that points nowhere, since
    /// every save is injected.
    private static let source = ActiveTileSource(
        providerID: TileProvider.stadiaOutdoors.id,
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 12
    )

    private let sandbox = TileSandbox()
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    /// An idle downloader of this suite's own: the deletion stands one down,
    /// and reaching for the app's registry would stand down whatever another
    /// suite happened to be running.
    private func idleDownloader() -> OfflineTileDownloader {
        OfflineTileDownloader(isOnline: { false }, registry: OfflineDownloadRegistry())
    }

    /// Two hikes over the same ground, both saved, claiming by auto-saved key
    /// so the claim is exactly the two tiles on disk rather than a recomputed
    /// route grid.
    private func sandboxWithSharedTile() throws -> (deleting: Hike, survivor: Hike) {
        try sandbox.save(key: Self.sharedKey)
        try sandbox.save(key: Self.exclusiveKey)
        let deleting = Fixture.hike(in: context, title: "Deleting its map")
        let survivor = Fixture.hike(in: context, title: "Still on the device")
        deleting.autoSavedTileKeys = [Self.sharedKey, Self.exclusiveKey]
        deleting.mergeOfflineDownload(
            OfflineDownloadRecord(providerID: TileProvider.default.id, maxZoom: 12)
        )
        survivor.autoSavedTileKeys = [Self.sharedKey]
        try context.save()
        return (deleting, survivor)
    }

    // MARK: What the commit carries

    /// The window the whole ordering argument is about: the app is killed
    /// between the manifest change and the file removals, and only one way
    /// round survives it. Emptying the manifests is the change being written,
    /// and every tile it frees is still on disk as it lands — so a kill there
    /// leaves durable tiles no hike claims, which the launch trim reclaims,
    /// rather than a hike claiming tiles that are gone, which nothing can.
    @Test("the emptied manifest is on disk before a single tile file is erased")
    func deletionSavesBeforeErasing() async throws {
        let (deleting, survivor) = try sandboxWithSharedTile()

        var manifestAtCommit: (downloads: Int, keys: Int)?
        var tilesAtCommit: (shared: Bool, exclusive: Bool)?
        let outcome = StoredTileDeletion.delete(
            storedTilesOf: deleting,
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil),
            downloader: idleDownloader(),
            fetchingHikes: { [deleting, survivor] },
            save: { modelContext in
                manifestAtCommit = (deleting.offlineDownloads.count, deleting.autoSavedTileKeys.count)
                tilesAtCommit = (sandbox.isSaved(Self.sharedKey), sandbox.isSaved(Self.exclusiveKey))
                try modelContext.save()
            }
        )

        guard case let .committed(deletionPlan) = outcome else {
            Issue.record("the deletion was refused")
            return
        }
        #expect(manifestAtCommit?.downloads == 0, "the forgotten downloads are what the save is for")
        #expect(manifestAtCommit?.keys == 0)
        #expect(
            tilesAtCommit?.shared == true && tilesAtCommit?.exclusive == true,
            """
            A tile erased before the commit is one a refused save brings the claim back for: the hike \
            goes on reporting a saved map that is not there, and nothing can re-download it.
            """
        )

        await deletionPlan.removeExclusiveTiles(from: sandbox.cache)
        #expect(!sandbox.isSaved(Self.exclusiveKey), "and then the tiles really do go")
        #expect(sandbox.isSaved(Self.sharedKey), "except the one the surviving hike still claims")
        #expect(survivor.autoSavedTileKeys == [Self.sharedKey])
    }

    // MARK: A store that says no

    /// The refusal, from the walker's side: they tapped Delete, the store
    /// would not take it, and what they are left with is the hike exactly as
    /// it was — every byte of it still counted, still claimed, still on disk.
    @Test("a refused save deletes nothing and leaves the manifest claiming what is there")
    func refusedSaveKeepsEveryTile() throws {
        let (deleting, survivor) = try sandboxWithSharedTile()

        let outcome = StoredTileDeletion.delete(
            storedTilesOf: deleting,
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil),
            downloader: idleDownloader(),
            fetchingHikes: { [deleting, survivor] },
            save: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        guard case .refused(.notSaved) = outcome else {
            Issue.record("a save that threw must be reported as a refusal the screen can say")
            return
        }
        #expect(
            Set(deleting.autoSavedTileKeys) == [Self.sharedKey, Self.exclusiveKey],
            "a manifest left empty in the context is coverage the next autosave forgets without a word"
        )
        #expect(deleting.offlineDownloads.count == 1)
        #expect(sandbox.isSaved(Self.sharedKey))
        #expect(sandbox.isSaved(Self.exclusiveKey), "and nothing was deleted for a change that never landed")
    }

    /// The other half of putting it back. Auto-save is switched off on the way
    /// down — a hike whose map was just deleted must not start saving it again
    /// on the next pan — and that move folds the last drain window's tiles out
    /// of the store's pending set and into the manifest, which the refusal
    /// then restores to what it was before them. Left unfinished, a transient
    /// save failure would cost the walker those tiles at the next launch trim
    /// and silently stop auto-saving a hike still on screen.
    @Test("a refused save gives the hike back its auto-save and the tiles it had just folded in")
    func refusedSaveRestoresAutoSave() async throws {
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        try context.save()
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        try sandbox.browse(key: Self.corridorKey)
        let store = sandbox.store
        await offMain {
            store.considerPersisting(
                key: Self.corridorKey,
                z: Self.corridorTile.z,
                x: Self.corridorTile.x,
                y: Self.corridorTile.y
            )
        }
        try #require(sandbox.isSaved(Self.corridorKey), "precondition: the tile really did reach durable storage")
        try #require(
            hike.autoSavedTileKeys.isEmpty,
            "precondition: the claim is still only in the store's pending set"
        )

        let outcome = StoredTileDeletion.delete(
            storedTilesOf: hike,
            autoSave: controller,
            downloader: idleDownloader(),
            fetchingHikes: { [hike] },
            save: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        guard case .refused(.notSaved) = outcome else {
            Issue.record("a save that threw must be reported as a refusal")
            return
        }
        #expect(
            hike.autoSavedTileKeys == [Self.corridorKey],
            """
            The fold has to land on top of the restored manifest. Without it the tile is durable, claimed \
            by nobody, and deleted at the next launch trim — for a hike the walker still has.
            """
        )
        #expect(hike.autoSaveTilesEnabled, "and the switch the walker never touched is back on")
        #expect(controller.currentHike?.id == hike.id, "nothing else re-arms it: the selection never changed")
        #expect(sandbox.isSaved(Self.corridorKey))
    }

    /// A download outlives the screen that started it, so the walker can reach
    /// this button while tiles are still landing. A committed deletion stands
    /// that run down — its tiles are precisely the ones no hike claims yet, so
    /// left running it would claim back coverage that was just deleted — but a
    /// *refused* one must not: nothing was deleted, so there is nothing for
    /// the run to resurrect, and cancelling it would cost the walker a
    /// download they never cancelled.
    @Test("a refused deletion leaves a download in flight alone")
    func refusedSaveLeavesTheDownloadRunning() async throws {
        let (deleting, survivor) = try sandboxWithSharedTile()
        let held = HeldSaves()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            registry: OfflineDownloadRegistry(),
            saveTile: { _, _ in await held.save() }
        )
        downloader.start(
            route: deleting.route,
            source: Self.source,
            claim: Fixture.unrecordedClaim,
        )
        await downloader.waitForPlanning()
        try #require(downloader.isRunning, "precondition: the run is in flight")

        let outcome = StoredTileDeletion.delete(
            storedTilesOf: deleting,
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil),
            downloader: downloader,
            fetchingHikes: { [deleting, survivor] },
            save: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        guard case .refused = outcome else {
            Issue.record("a save that threw must be reported as a refusal")
            return
        }
        #expect(downloader.isRunning, "a deletion that did not happen is not a reason to stop a download")

        await held.release()
        await downloader.waitForCurrentRun()
    }

    // MARK: A library that cannot be read

    /// The fail-closed half, checked here for what it leaves *unwritten*
    /// rather than for what it frees. A survivor missing from the claim set is
    /// a hike whose downloaded map would be deleted while its manifest went on
    /// listing it, so the deletion is refused — and because every read that
    /// can refuse happens before the first write, the refusal costs the walker
    /// nothing at all: not the manifest, not auto-save, not a tile.
    @Test("a library that cannot be read refuses before anything is written")
    func unreadableLibraryWritesNothing() async throws {
        let (deleting, _) = try sandboxWithSharedTile()
        deleting.autoSaveTilesEnabled = true
        try context.save()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        controller.hikeSelectionChanged(to: deleting)
        await controller.waitForActivation()

        let outcome = StoredTileDeletion.delete(
            storedTilesOf: deleting,
            autoSave: controller,
            downloader: idleDownloader(),
            fetchingHikes: { throw LibraryReadFailure() }
        )

        guard case .refused(.claimsUnreadable) = outcome else {
            Issue.record("a claim set that could not be established must refuse, and say which refusal it is")
            return
        }
        #expect(Set(deleting.autoSavedTileKeys) == [Self.sharedKey, Self.exclusiveKey])
        #expect(deleting.offlineDownloads.count == 1)
        #expect(deleting.autoSaveTilesEnabled, "auto-save is switched off by a deletion, not by an attempt at one")
        #expect(controller.currentHike?.id == deleting.id)
        #expect(sandbox.isSaved(Self.sharedKey))
        #expect(sandbox.isSaved(Self.exclusiveKey))
    }
}

/// Holds every stubbed save open until the test lets it go, so a run is
/// genuinely still in flight when the deletion lands.
private actor HeldSaves {
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func save() async -> Bool {
        if !isReleased {
            await withCheckedContinuation { waiting.append($0) }
        }
        return true
    }

    func release() {
        isReleased = true
        let resumed = waiting
        waiting.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}
