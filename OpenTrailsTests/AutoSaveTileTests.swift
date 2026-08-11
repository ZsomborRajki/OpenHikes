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

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import OpenTrails

/// Serialized as one group: `AutoSaveTileStore.shared` is a process-wide
/// singleton with exactly one active hike, mirroring the app — so the store
/// tests and the controller tests can't run alongside each other either.
@Suite("Auto-save", .serialized)
struct AutoSaveTests {

@Suite("Tile store")
struct TileStoreTests {
    private let store = AutoSaveTileStore.shared
    private let hikeID = UUID()
    /// Keys are namespaced per test run so nothing collides with a real
    /// cached tile — the tile's own z/x/y is passed separately anyway.
    private let namespace = "test-\(UUID().uuidString)"

    init() {
        store.clearActiveHike()
    }

    private func key(_ z: Int, _ x: Int, _ y: Int) -> String {
        "\(namespace)/\(z)/\(x)/\(y)@2.0"
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
        if browsed { try TileStore.browse(key: key) }
        let store = store
        await offMain { store.considerPersisting(key: key, z: tile.z, x: tile.x, y: tile.y) }
    }

    private func cleanUp(_ keys: [String]) async {
        await offMain { TileCache.shared.removeTiles(forKeys: keys) }
        store.clearActiveHike()
    }

    // MARK: What gets kept

    @Test("a browsed tile near the trail is saved and reported back")
    func savesTilesOnTheTrail() async throws {
        activate()
        let key = key(16, 1, 1)
        try await persist(key: key, tile: tile())

        #expect(store.drainPendingKeys(for: hikeID) == [key])
        #expect(TileStore.isSaved(key), "the tile should be kept for offline use, not just recorded")
        #expect(!TileStore.isBrowsed(key), "and moved out of the cache rather than copied out of it")
        await cleanUp([key])
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
        #expect(!TileStore.isSaved(key))
        #expect(TileStore.isBrowsed(key), "it is still cache, and still clearable as such")
        await cleanUp([key])
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
        await cleanUp([key])
    }

    /// Keys already in the hike's manifest are seeded in on activation, so a
    /// tile saved in a previous session isn't rewritten in this one.
    @Test("keys carried over from a previous session are already known")
    func dedupesAcrossSessions() async throws {
        let key = key(16, 3, 3)
        activate(knownKeys: [key])
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
        await cleanUp([key])
    }

    @Test("an expired known tile is saved again when viewed")
    func refreshesExpiredKnownTile() async throws {
        let key = key(16, 3, 4)
        try TileStore.browse(key: key)
        #expect(await offMain { TileCache.shared.promoteCachedTile(forKey: key) })
        try TileStore.age(key: key, byDays: 8)
        _ = await offMain { TileCache.shared.removeExpiredTiles() }
        #expect(!TileStore.isSaved(key), "precondition: launch cleanup removed the expired copy")

        activate(knownKeys: [key])
        try await persist(key: key, tile: tile())

        #expect(TileStore.isSaved(key), "the stale manifest entry must not prevent fresh bytes being saved")
        #expect(store.drainPendingKeys(for: hikeID).isEmpty, "the key was already present in the manifest")
        await cleanUp([key])
    }

    // MARK: The cap

    @Test("the cap is measured against everything the hike already claims")
    func capCountsExistingKeys() async throws {
        let existing = Set((0..<AutoSaveTileStore.tileCap).map { "\(namespace)/16/\($0)/0@2.0" })
        activate(knownKeys: existing)
        #expect(store.isCapReached(for: hikeID))

        let key = key(16, 4, 4)
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID).isEmpty, "nothing more should be saved once the cap is reached")
        await cleanUp([key])
    }

    @Test("the cap belongs to the active hike, not to the app")
    func capIsPerHike() {
        activate(knownKeys: Set((0..<AutoSaveTileStore.tileCap).map { "\(namespace)/16/\($0)/0@2.0" }))
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
        #expect(!TileStore.isSaved(key))
        await cleanUp([key])
    }

    @Test("suspending atomically blocks new tile claims until resume")
    func suspensionBlocksNewClaims() async throws {
        activate()
        #expect(store.suspendAndSnapshotPendingKeys(for: hikeID).isEmpty)

        let key = key(16, 5, 6)
        try await persist(key: key, tile: tile())
        #expect(!TileStore.isSaved(key))
        #expect(TileStore.isBrowsed(key), "a tile finishing after suspension must remain ordinary cache")

        store.resumePersisting(for: hikeID)
        try await persist(key: key, tile: tile())
        #expect(store.drainPendingKeys(for: hikeID) == [key])
        #expect(TileStore.isSaved(key))
        await cleanUp([key])
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
        await cleanUp([key])
    }

    @Test("switching hikes drops the previous one's pending keys")
    func switchingHikesResetsPending() async throws {
        activate()
        let key = key(16, 7, 7)
        try await persist(key: key, tile: tile())

        store.setActiveHike(id: UUID(), route: Fixture.coordinates(Fixture.ridgeRoute), knownKeys: [])
        #expect(store.drainPendingKeys(for: hikeID).isEmpty)
        await cleanUp([key])
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

        #expect(!TileStore.isSaved(key), "precondition: nothing was saved")
        #expect(store.drainPendingKeys(for: hikeID).isEmpty, "a tile that isn't on disk must not be recorded as saved")
        await cleanUp([key])
    }
}

@MainActor
@Suite("Controller")
struct ControllerTests {
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
        AutoSaveTileStore.shared.clearActiveHike()
    }

    /// A hike whose manifest is already full. Activation seeds the store from
    /// that manifest, so "is the cap reached for this hike?" doubles as an
    /// observable answer to "did the controller actually activate it?".
    private func fullHike(configure: (Hike) -> Void = { _ in }) -> Hike {
        Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = (0..<AutoSaveTileStore.tileCap).map { "saved/\($0)" }
            configure(hike)
        }
    }

    @Test("selecting a hike makes it the one being saved for")
    func selectionActivates() {
        let controller = AutoSaveController()
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        #expect(controller.isCapReached(for: hike), "the store should be active, seeded from this hike's manifest")
    }

    @Test("deselecting stops saving")
    func deselectionDeactivates() {
        let controller = AutoSaveController()
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        controller.hikeSelectionChanged(to: nil)
        #expect(!controller.isCapReached(for: hike), "nothing should be active once the selection is cleared")
    }

    @Test("selecting another hike hands auto-save over to it")
    func selectionFollowsTheMap() {
        let controller = AutoSaveController()
        let first = fullHike()
        let second = Fixture.hike(title: "Second", in: context)
        controller.hikeSelectionChanged(to: first)
        controller.hikeSelectionChanged(to: second)
        #expect(!controller.isCapReached(for: first), "the previous hike is no longer the active one")
    }

    /// A hike with auto-save switched off is browsed like any other; nothing
    /// should be saved for it.
    @Test("a hike with auto-save off is never activated")
    func disabledHikeIsNotActivated() {
        let controller = AutoSaveController()
        let hike = fullHike { $0.autoSaveTilesEnabled = false }
        controller.hikeSelectionChanged(to: hike)
        #expect(!controller.isCapReached(for: hike))
    }

    /// A one-point hike has no corridor worth speaking of, and the toggle is
    /// disabled for it in the UI.
    @Test("a hike with fewer than two points is never activated")
    func degenerateHikeIsNotActivated() {
        let controller = AutoSaveController()
        let hike = Fixture.hike(
            route: [RouteCoordinate(latitude: 47.63, longitude: 12.86)],
            in: context
        ) { $0.autoSavedTileKeys = (0..<AutoSaveTileStore.tileCap).map { "saved/\($0)" } }
        controller.hikeSelectionChanged(to: hike)
        #expect(!controller.isCapReached(for: hike))
    }

    @Test("the toggle writes through to the hike, and starts and stops saving")
    func toggleWritesThrough() {
        let controller = AutoSaveController()
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
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let store = AutoSaveTileStore.shared
        let anchor = hike.coordinates[2]
        let z = 17
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let y = SlippyTileMath.tileY(anchor.latitude, z: z)
        let keys = ["autosave-test/\(z)/\(x)/\(y)@2.0", "autosave-test/\(z)/\(x + 1)/\(y)@2.0"]
        for key in keys {
            try TileStore.browse(key: key)
            await offMain { store.considerPersisting(key: key, z: z, x: x, y: y) }
        }

        controller.flushPendingKeys()
        #expect(Set(hike.autoSavedTileKeys) == Set(keys))

        // A second drain has nothing left to add — no duplicates in the manifest.
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys.count == keys.count)

        await offMain { TileCache.shared.removeTiles(forKeys: keys) }
        AutoSaveTileStore.shared.clearActiveHike()
    }

    @Test("a failed suspension save keeps ownership pending for retry")
    func failedSuspensionSaveKeepsPendingKeys() async throws {
        struct SaveFailure: Error {}

        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let store = AutoSaveTileStore.shared
        let anchor = hike.coordinates[2]
        let z = 17
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let y = SlippyTileMath.tileY(anchor.latitude, z: z)
        let key = "autosave-suspension-test/\(z)/\(x)/\(y)@2.0"
        try TileStore.browse(key: key)
        await offMain { store.considerPersisting(key: key, z: z, x: x, y: y) }

        controller.sceneWillResignActive { throw SaveFailure() }
        #expect(hike.autoSavedTileKeys.isEmpty, "a failed save must roll back the in-memory manifest update")
        #expect(
            store.suspendAndSnapshotPendingKeys(for: hike.id) == [key],
            "ownership must remain pending until persistence succeeds"
        )

        controller.sceneDidBecomeActive()
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [key])

        await offMain { TileCache.shared.removeTiles(forKeys: [key]) }
        AutoSaveTileStore.shared.clearActiveHike()
    }

    @Test("suspension saves ownership already folded into the model")
    func suspensionSavesPreviouslyDrainedOwnership() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let store = AutoSaveTileStore.shared
        let anchor = hike.coordinates[2]
        let z = 17
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let y = SlippyTileMath.tileY(anchor.latitude, z: z)
        let key = "autosave-drained-test/\(z)/\(x)/\(y)@2.0"
        try TileStore.browse(key: key)
        await offMain { store.considerPersisting(key: key, z: z, x: x, y: y) }
        controller.flushPendingKeys()

        var saveWasCalled = false
        controller.sceneWillResignActive { saveWasCalled = true }
        #expect(saveWasCalled, "suspension must save even when the timer already drained every pending key")

        await offMain { TileCache.shared.removeTiles(forKeys: [key]) }
        AutoSaveTileStore.shared.clearActiveHike()
    }

    @Test("selection changes during suspension preserve failed-save ownership")
    func suspendedSelectionChangePreservesPendingKeys() async throws {
        struct SaveFailure: Error {}

        let controller = AutoSaveController()
        let first = Fixture.hike(in: context)
        let second = Fixture.hike(title: "Second", in: context)
        controller.hikeSelectionChanged(to: first)

        let store = AutoSaveTileStore.shared
        let anchor = first.coordinates[2]
        let z = 17
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let y = SlippyTileMath.tileY(anchor.latitude, z: z)
        let key = "autosave-deferred-selection-test/\(z)/\(x)/\(y)@2.0"
        try TileStore.browse(key: key)
        await offMain { store.considerPersisting(key: key, z: z, x: x, y: y) }

        controller.sceneWillResignActive { throw SaveFailure() }
        controller.hikeSelectionChanged(to: second)
        #expect(
            store.suspendAndSnapshotPendingKeys(for: first.id) == [key],
            "changing selection while suspended must not replace the store's retained ownership"
        )

        controller.sceneDidBecomeActive()
        #expect(first.autoSavedTileKeys == [key])

        await offMain { TileCache.shared.removeTiles(forKeys: [key]) }
        AutoSaveTileStore.shared.clearActiveHike()
    }
}

}
