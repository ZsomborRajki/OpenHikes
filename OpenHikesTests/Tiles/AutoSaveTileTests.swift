//
//  AutoSaveTileTests.swift
//  OpenHikesTests
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
//  its own store with one active hike of its own, rather than the process-wide
//  singletons the app drives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
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

    /// A tile the manifest already names, whose durable copy has since been
    /// deleted — by Settings' cache clear, or by a reclaim at a provider's
    /// ceiling — is saved again the next time it is viewed. The stale manifest
    /// entry must not be read as "already on disk".
    ///
    /// Deleted outright rather than aged past the TTL, which no longer removes
    /// anything: saved coverage a week old is still saved, and the promote path
    /// is required to say so. That case is
    /// `TileDurableAccountingTests.promoteTreatsStaleCoverageAsSaved`.
    @Test("a known tile whose durable copy is gone is saved again when viewed")
    func refreshesExpiredKnownTile() async throws {
        let key = key(16, 3, 4)
        try sandbox.browse(key: key)
        #expect(await offMain { sandbox.cache.promoteCachedTile(forKey: key) })
        try FileManager.default.removeItem(at: sandbox.savedFile(for: key))
        #expect(!sandbox.isSaved(key), "precondition: the durable copy is gone")

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
