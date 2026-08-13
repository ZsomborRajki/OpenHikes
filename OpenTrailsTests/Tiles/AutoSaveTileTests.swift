//
//  AutoSaveTileTests.swift
//  OpenTrailsTests
//
//  Auto-save is the only offline mechanism OpenStreetMap's tile policy
//  allows, so for the default provider it is *the* offline feature: tiles the
//  user has actually browsed, near the trail they're browsing, persisted as a
//  side effect of drawing them.
//
//  Two halves are checked here. `AutoSaveTileStore` decides, on the tile
//  thread, whether a given tile is worth keeping (in the corridor, under the
//  cap, not already saved). `AutoSaveController` decides which hike that is,
//  and folds the saved keys back into its SwiftData manifest — the record
//  that later measures and frees them.
//
//  Every suite here builds its own `TileSandbox`: its own tile directories and
//  its own store with one active hike of its own. These used to be nested
//  inside a `.serialized` parent because they drove the process-wide
//  singletons instead, which made "add a suite" a question about parallelism.
//

import CoreLocation
import Foundation
@testable import OpenTrails
import SwiftData
import Testing

@Suite("Tile store")
struct TileStoreTests {
    private let sandbox = TileSandbox()
    private let hikeID = UUID()

    private var store: AutoSaveTileStore { sandbox.store }

    private func key(_ z: Int, _ x: Int, _ y: Int) -> String {
        "\(z)/\(x)/\(y)@2.0"
    }

    /// Tile indices for a coordinate offset from the trail.
    private func tile(northMeters: Double = 0, eastMeters: Double = 0, z: Int = 16) -> (z: Int, x: Int, y: Int) {
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[2]
        let latitude = anchor.latitude + northMeters / 111_320
        let longitude = anchor.longitude + eastMeters / (111_320 * cos(anchor.latitude * .pi / 180))
        return (z, SlippyTileMath.tileX(longitude, z: z), SlippyTileMath.tileY(latitude, z: z))
    }

    private func activate(knownKeys: Set<String> = []) {
        store.setActiveHike(
            id: hikeID,
            route: Fixture.coordinates(Fixture.ridgeRoute),
            knownKeys: knownKeys
        )
    }

    /// Runs the tile-thread path: the tile has been drawn, so its bytes are in
    /// the browsing cache, and `considerPersisting` decides whether to keep
    /// them. Asserts it isn't on main (it moves a file).
    ///
    /// Pass `browsed: false` for the case where the bytes aren't there.
    private func persist(key: String, tile: (z: Int, x: Int, y: Int), browsed: Bool = true) async throws {
        if browsed { try sandbox.browse(key: key) }
        await offMain { [store] in store.considerPersisting(key: key, z: tile.z, x: tile.x, y: tile.y) }
    }

    // MARK: What gets kept

    @Test("a browsed tile near the trail is saved and reported back")
    func savesTilesOnTheTrail() async throws {
        activate()
        let key = key(16, 1, 1)
        try await persist(key: key, tile: tile())

        #expect(store.drainPendingKeys(for: hikeID) == [key])
        #expect(sandbox.isSaved(key), "the tile should be kept for offline use, not just recorded")
        #expect(!sandbox.isBrowsed(key), "and moved out of the cache rather than copied out of it")
    }

    /// Panning away from the trail is browsing, not saving — otherwise a
    /// hike's offline budget fills with wherever the user happened to look.
    /// The tile stays in the cache, where it can be reclaimed; it just isn't
    /// promoted to something the hike is keeping.
    @Test("a tile far from the trail is not saved")
    func ignoresTilesOffCorridor() async throws {
        activate()
        let key = key(16, 9, 9)
        try await persist(key: key, tile: tile(northMeters: 25_000))

        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
        #expect(!sandbox.isSaved(key))
        #expect(sandbox.isBrowsed(key), "it is still cache, and still clearable as such")
    }

    /// Re-viewing the same tile (every pan back and forth does) must not
    /// move it a second time.
    @Test("a tile already saved isn't saved twice")
    func dedupesWithinASession() async throws {
        activate()
        let key = key(16, 2, 2)
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID) == [key])

        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
    }

    /// Keys already in the hike's manifest are seeded in on activation, so a
    /// tile saved in a previous session isn't rewritten in this one.
    @Test("keys carried over from a previous session are already known")
    func dedupesAcrossSessions() async throws {
        let key = key(16, 3, 3)
        activate(knownKeys: [key])
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
    }

    @Test("an expired known tile is saved again when viewed")
    func refreshesExpiredKnownTile() async throws {
        let key = key(16, 3, 4)
        try sandbox.browse(key: key)
        #expect(await offMain { sandbox.cache.promoteCachedTile(forKey: key) })
        try sandbox.age(key: key, byDays: 8)
        _ = await offMain { sandbox.cache.removeExpiredTiles() }
        #expect(!sandbox.isSaved(key), "precondition: launch cleanup removed the expired copy")

        activate(knownKeys: [key])
        try await persist(key: key, tile: tile())

        #expect(sandbox.isSaved(key), "the stale manifest entry must not prevent fresh bytes being saved")
        #expect(store.drainPendingKeys(for: hikeID).isEmpty, "the key was already present in the manifest")
    }

    // MARK: The cap

    @Test("the cap is measured against everything the hike already claims")
    func capCountsExistingKeys() async throws {
        let existing = Set((0..<AutoSaveTileStore.tileCap).map { "16/\($0)/0@2.0" })
        activate(knownKeys: existing)
        #expect(store.isCapReached(for: hikeID))

        let key = key(16, 4, 4)
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID).isEmpty, "nothing more should be saved once the cap is reached")
    }

    @Test("the cap belongs to the active hike, not to the app")
    func capIsPerHike() {
        activate(knownKeys: Set((0..<AutoSaveTileStore.tileCap).map { "16/\($0)/0@2.0" }))
        #expect(store.isCapReached(for: hikeID))
        #expect(!store.isCapReached(for: UUID()), "a different hike has its own budget")
        store.clearActiveHike()
        #expect(!store.isCapReached(for: hikeID))
    }

    // MARK: Following the selection

    @Test("nothing is saved while no hike is active")
    func inactiveStoreSavesNothing() async throws {
        store.clearActiveHike()
        let key = key(16, 5, 5)
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
        #expect(!sandbox.isSaved(key))
    }

    @Test("suspending atomically blocks new tile claims until resume")
    func suspensionBlocksNewClaims() async throws {
        activate()
        #expect(store.suspendAndSnapshotPendingKeys(for: hikeID).isEmpty)

        let key = key(16, 5, 6)
        try await persist(key: key, tile: tile())
        #expect(!sandbox.isSaved(key))
        #expect(sandbox.isBrowsed(key), "a tile finishing after suspension must remain ordinary cache")

        store.resumePersisting(for: hikeID)
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID) == [key])
        #expect(sandbox.isSaved(key))
    }

    /// The drain is keyed by hike so a selection change mid-flight can't
    /// splice one trail's tiles into another's manifest.
    @Test("pending keys are only handed to the hike they belong to")
    func drainIsScopedToTheHike() async throws {
        activate()
        let key = key(16, 6, 6)
        try await persist(key: key, tile: tile())

        #expect(store.drainPendingKeys(for: UUID()).isEmpty)
        #expect(store.drainPendingKeys(for: hikeID) == [key], "the real hike's keys must survive the wrong-hike query")
    }

    @Test("switching hikes drops the previous one's pending keys")
    func switchingHikesResetsPending() async throws {
        activate()
        let key = key(16, 7, 7)
        try await persist(key: key, tile: tile())

        store.setActiveHike(id: UUID(), route: Fixture.coordinates(Fixture.ridgeRoute), knownKeys: [])
        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
    }

    // MARK: Failure to save

    /// A tile is claimed before its bytes have moved. If there is nothing in
    /// the cache to move — the tile came from memory after an OS purge of
    /// `Caches` — the key would otherwise be left claiming a tile that was
    /// never saved: it counts against the 3,000-tile cap, it is reported as
    /// saved, and being "known" it is never reconsidered.
    @Test("a tile with nothing cached to save isn't reported as saved")
    func uncachedTileIsNotClaimed() async throws {
        activate()
        let key = key(16, 8, 8)
        try await persist(key: key, tile: tile(), browsed: false)

        #expect(!sandbox.isSaved(key), "precondition: nothing was saved")
        #expect(store.drainPendingKeys(for: hikeID).isEmpty, "a tile that isn't on disk must not be recorded as saved")
    }

    @Test("concurrent drains claim each tile exactly once")
    func concurrentClaimsRemainConsistent() async throws {
        activate()
        let tile = tile()
        let keys = (0..<48).map { idx in
            "concurrent/\(tile.z)/\(tile.x)/\(tile.y)-\(idx)@2.0"
        }
        for key in keys {
            try sandbox.browse(key: key)
        }

        await withTaskGroup(of: Void.self) { [store] group in
            for key in keys {
                for _ in 0..<4 {
                    group.addTask {
                        await offMain {
                            store.considerPersisting(
                                key: key,
                                z: tile.z,
                                x: tile.x,
                                y: tile.y
                            )
                        }
                    }
                }
            }
        }

        #expect(store.drainPendingKeys(for: hikeID) == Set(keys))
        #expect(keys.allSatisfy(sandbox.isSaved))
        #expect(keys.allSatisfy { !sandbox.isBrowsed($0) })
        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
    }
}

@Suite("Auto-save controller")
struct ControllerTests {
    private let sandbox = TileSandbox()
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    private func makeController() -> AutoSaveController {
        AutoSaveController(store: sandbox.store)
    }

    /// A hike whose manifest is already full. Activation seeds the store from
    /// that manifest, so "is the cap reached for this hike?" doubles as an
    /// observable answer to "did the controller actually activate it?".
    private func fullHike(configure: (Hike) -> Void = { _ in /* no-op */ }) -> Hike {
        Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = (0..<AutoSaveTileStore.tileCap).map { "saved/\($0)" }
            configure(hike)
        }
    }

    /// Saves one tile against the active hike through the tile-thread path.
    private func persist(key: String, near hike: Hike, z: Int = 17) async throws {
        let anchor = hike.coordinates[2]
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let y = SlippyTileMath.tileY(anchor.latitude, z: z)
        try sandbox.browse(key: key)
        await offMain { sandbox.store.considerPersisting(key: key, z: z, x: x, y: y) }
    }

    @Test("selecting a hike makes it the one being saved for")
    func selectionActivates() {
        let controller = makeController()
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        #expect(controller.isCapReached(for: hike), "the store should be active, seeded from this hike's manifest")
    }

    @Test("deselecting stops saving")
    func deselectionDeactivates() {
        let controller = makeController()
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        controller.hikeSelectionChanged(to: nil)
        #expect(!controller.isCapReached(for: hike), "nothing should be active once the selection is cleared")
    }

    @Test("selecting another hike hands auto-save over to it")
    func selectionFollowsTheMap() {
        let controller = makeController()
        let first = fullHike()
        let second = Fixture.hike(in: context, title: "Second")
        controller.hikeSelectionChanged(to: first)
        controller.hikeSelectionChanged(to: second)
        #expect(!controller.isCapReached(for: first), "the previous hike is no longer the active one")
    }

    /// A hike with auto-save switched off is browsed like any other; nothing
    /// should be saved for it.
    @Test("a hike with auto-save off is never activated")
    func disabledHikeIsNotActivated() {
        let controller = makeController()
        let hike = fullHike { $0.autoSaveTilesEnabled = false }
        controller.hikeSelectionChanged(to: hike)
        #expect(!controller.isCapReached(for: hike))
    }

    /// A one-point hike has no corridor worth speaking of, and the toggle is
    /// disabled for it in the UI.
    @Test("a hike with fewer than two points is never activated")
    func degenerateHikeIsNotActivated() {
        let controller = makeController()
        let hike = Fixture.hike(
            in: context,
            route: [RouteCoordinate(latitude: 47.63, longitude: 12.86)]
        ) { $0.autoSavedTileKeys = (0..<AutoSaveTileStore.tileCap).map { "saved/\($0)" } }
        controller.hikeSelectionChanged(to: hike)
        #expect(!controller.isCapReached(for: hike))
    }

    @Test("the toggle writes through to the hike, and starts and stops saving")
    func toggleWritesThrough() {
        let controller = makeController()
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)

        controller.setEnabled(false, for: hike)
        #expect(hike.autoSaveTilesEnabled == false)
        #expect(!controller.isCapReached(for: hike), "turning it off should stop the store tracking this hike")

        controller.setEnabled(true, for: hike)
        #expect(hike.autoSaveTilesEnabled == true)
        #expect(controller.isCapReached(for: hike), "turning it back on should resume from the same manifest")
    }

    /// The drain is what turns "saved on disk" into "recorded on the hike".
    /// Until it runs the tiles exist with nothing pointing at them, which is
    /// why the delete path flushes before it reads any manifest.
    @Test("draining folds newly saved keys into the hike's manifest")
    func flushMergesKeys() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let anchor = hike.coordinates[2]
        let z = 17
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let keys = ["autosave-test/\(z)/\(x)/a@2.0", "autosave-test/\(z)/\(x)/b@2.0"]
        for key in keys { try await persist(key: key, near: hike) }

        controller.flushPendingKeys()
        #expect(Set(hike.autoSavedTileKeys) == Set(keys))

        // A second drain has nothing left to add — no duplicates in the manifest.
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys.count == keys.count)
    }

    @Test("a failed suspension save keeps ownership pending for retry")
    func failedSuspensionSaveKeepsPendingKeys() async throws {
        struct SaveFailure: Error {}

        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let key = "autosave-suspension-test/17/1/1@2.0"
        try await persist(key: key, near: hike)

        controller.sceneWillResignActive { throw SaveFailure() }
        #expect(hike.autoSavedTileKeys.isEmpty, "a failed save must roll back the in-memory manifest update")
        #expect(
            sandbox.store.suspendAndSnapshotPendingKeys(for: hike.id) == [key],
            "ownership must remain pending until persistence succeeds"
        )

        controller.sceneDidBecomeActive()
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [key])
    }

    @Test("suspension saves ownership already folded into the model")
    func suspensionSavesPreviouslyDrainedOwnership() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        try await persist(key: "autosave-drained-test/17/1/1@2.0", near: hike)
        controller.flushPendingKeys()

        var saveWasCalled = false
        controller.sceneWillResignActive { saveWasCalled = true }
        #expect(saveWasCalled, "suspension must save even when the timer already drained every pending key")
    }

    @Test("selection changes during suspension preserve failed-save ownership")
    func suspendedSelectionChangePreservesPendingKeys() async throws {
        struct SaveFailure: Error {}

        let controller = makeController()
        let first = Fixture.hike(in: context)
        let second = Fixture.hike(in: context, title: "Second")
        controller.hikeSelectionChanged(to: first)

        let key = "autosave-deferred-selection-test/17/1/1@2.0"
        try await persist(key: key, near: first)

        controller.sceneWillResignActive { throw SaveFailure() }
        controller.hikeSelectionChanged(to: second)
        #expect(
            sandbox.store.suspendAndSnapshotPendingKeys(for: first.id) == [key],
            "changing selection while suspended must not replace the store's retained ownership"
        )

        controller.sceneDidBecomeActive()
        #expect(first.autoSavedTileKeys == [key])
    }
}

/// The lifecycle states the two suites above don't cross: the suspension
/// `sceneWillResignActive` enters, and the deletion paths that read a
/// hike's manifest in order to free tiles by it. Each is covered on its
/// own; what isn't is what the user-facing operations do *while*
/// suspension is in effect.
///
/// That matters because suspension defers selection changes rather than
/// applying them, while every deletion path in the app is specified as
/// "flush first, then read the manifest" — and an unflushed pending set is
/// durable tiles on disk with nothing left pointing at them.
@Suite("Auto-save lifecycle")
struct AutoSaveLifecycleTests {
    private let sandbox = TileSandbox()

    /// A tile inside the ridge fixture's corridor, saved through the same path
    /// the renderer uses so the store's pending set is populated for real.
    private func persistOneTile(key: String) async throws {
        try sandbox.browse(key: key)
        await offMain {
            sandbox.store.considerPersisting(key: key, z: 14, x: 2638, y: 6357)
        }
    }

    private func tileKey(_ id: String) -> String { "osm/14/2638/6357@2.0-\(id)" }

    /// Turning the Auto-Save toggle off is how the hike sheet's Delete button
    /// folds the last drain window's tiles into the manifest before reading
    /// it — `deleteStoredTiles()` calls `setEnabled(false, for:)` first,
    /// because "reading the manifest ahead of that would delete a snapshot
    /// taken up to two seconds ago and strand everything saved since —
    /// durably, where nothing would reclaim it."
    ///
    /// While suspended, `setEnabled` takes the deferred branch and returns
    /// *without* deactivating, so that flush never happens. What saves the
    /// delete is a second mechanism entirely: `sceneWillResignActive` already
    /// folded the pending set in on its way out, and `acceptsNewClaims` is
    /// false from that moment, so there is nothing left un-flushed to strand.
    ///
    /// Two independent guarantees standing on each other is worth a test of
    /// its own: the deferred branch is only safe *because* suspension both
    /// flushes and stops claiming, and neither of those facts is stated
    /// anywhere near `setEnabled`.
    @Test("a delete during suspension still sees every tile that reached disk")
    func disablingWhileSuspendedLosesNothing() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: hike)

        let key = tileKey(UUID().uuidString)
        try await persistOneTile(key: key)
        #expect(sandbox.isSaved(key), "precondition: it really did reach durable storage")

        // The scene resigns active — a phone call, a swipe up, App Switcher.
        controller.sceneWillResignActive { /* scene resigned active */ }
        // …and the user taps Delete on the hike sheet, whose first act is to
        // turn auto-save off. This is the branch that does not flush.
        controller.setEnabled(false, for: hike)

        #expect(
            hike.autoSavedTileKeys.contains(key),
            "the tile is durably on disk; the manifest is the only thing that can free it"
        )

        // And nothing new can be claimed in the window either, which is the
        // other half of why the deferred branch gets away with it.
        let laterKey = tileKey(UUID().uuidString)
        try await persistOneTile(key: laterKey)
        #expect(!sandbox.isSaved(laterKey), "a suspended store must not take new claims")
    }

    /// The same window, reached the other way: deleting the hike outright.
    /// `hikeWillBeDeleted` exists precisely to flush regardless of suspension
    /// (`flushWhileSuspended: true`), so this one must hold — it's the
    /// contrast that shows the gap above is an omission rather than the
    /// intended policy.
    @Test("deleting a hike folds in what it just saved, suspended or not")
    func deletingWhileSuspendedStillFlushes() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: hike)

        let key = tileKey(UUID().uuidString)
        try await persistOneTile(key: key)

        controller.sceneWillResignActive { /* scene resigned active */ }
        controller.hikeWillBeDeleted(hike)

        #expect(
            hike.autoSavedTileKeys.contains(key),
            "the delete path flushes past suspension so the tiles it frees are all of them"
        )
    }

    /// `sceneWillResignActive` appends the pending snapshot to the manifest
    /// and rolls it back if the save throws. The rollback removes by *count*
    /// (`removeSubrange(previousCount...)`), which is only correct while
    /// nothing else has appended in between — and `flushPendingKeys` runs on a
    /// two-second timer that is not stopped for the duration.
    ///
    /// Pinned rather than fixed: the window is small and the timer is
    /// main-actor bound, so today the two can't interleave. It becomes a real
    /// corruption the moment any flush moves off that timer.
    @Test("a failed suspension save leaves the manifest exactly as it found it")
    func failedSuspensionSaveRestoresTheManifest() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        hike.autoSavedTileKeys = ["osm/14/1/1@2.0", "osm/14/1/2@2.0"]
        controller.hikeSelectionChanged(to: hike)
        let before = hike.autoSavedTileKeys

        try await persistOneTile(key: tileKey(UUID().uuidString))

        struct SaveFailed: Error {}
        controller.sceneWillResignActive { throw SaveFailed() }

        #expect(hike.autoSavedTileKeys == before, "a failed save must not leave a half-written manifest")
    }

    /// Two hikes over the same ground both auto-save, and the cap is per hike.
    /// Nothing pins what happens when the *second* one is activated while the
    /// first still has pending keys that the activation's own flush is
    /// supposed to hand back — `activate` flushes before replacing the store's
    /// state, and this is the assertion that keeps that ordering honest under
    /// a same-hike re-activation, which the app does on every selection change
    /// (`OpenTrailsModel.selectedHikeDidChange` and `HikeDetailView.task` both
    /// call it).
    @Test("re-selecting the same hike doesn't lose or duplicate its pending tiles")
    func reactivatingTheSameHikeIsIdempotent() async throws {
        let context = try Fixture.modelContext()
        let controller = AutoSaveController(store: sandbox.store)
        let hike = Fixture.hike(in: context) { $0.autoSaveTilesEnabled = true }
        controller.hikeSelectionChanged(to: hike)

        let key = tileKey(UUID().uuidString)
        try await persistOneTile(key: key)

        // The two call sites that both fire for one tap.
        controller.hikeSelectionChanged(to: hike)
        controller.hikeSelectionChanged(to: hike)
        controller.flushPendingKeys()

        #expect(hike.autoSavedTileKeys.filter { $0 == key }.count == 1, "one tile, one entry")
    }
}
