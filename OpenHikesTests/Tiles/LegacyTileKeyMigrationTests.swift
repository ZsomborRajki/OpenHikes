//
//  LegacyTileKeyMigrationTests.swift
//  OpenHikesTests
//
//  What happens to a device that already had tiles when display scale left the
//  cache key.
//
//  The change itself is prospective: every tile saved after it is named the
//  way the renderer asks for it. Everything already on the phone is named the
//  old way, in manifests that are stored verbatim and unioned into the claim
//  set verbatim — so without this migration an upgrade turns a walker's
//  downloaded map into files nothing can read, still claimed, still reported
//  as offline storage, and still refetched tile by tile.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The failure a `ModelContext` cannot be made to produce.
private struct ManifestSaveFailure: Error {}

@Suite("Legacy tile key migration")
struct LegacyTileKeyMigrationTests {
    /// This suite's own tile directories and auto-save store, so it neither
    /// sees nor disturbs any other suite's tiles.
    private let sandbox = TileSandbox()
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    // MARK: - Harness

    /// The launch pass, run against this suite's own store and cache.
    ///
    /// The fixture is persisted first, so the rows this fetches are the ones a
    /// store of the old era would be handing the app at launch rather than
    /// pending inserts.
    private func migrate(saving save: () throws -> Void = { /* no-op */ }) throws {
        try context.save()
        LegacyTileKeyMigration.run(
            cache: sandbox.cache,
            fetchingLocalStates: { try context.fetch(FetchDescriptor<HikeLocalState>()) },
            saving: { try save(); try context.save() }
        )
    }

    /// What the hike sheet adds up to and what the launch sweep spares.
    private func claimedKeys(of hike: Hike) async throws -> Set<String> {
        let ownership = TileOwnership(hike)
        return try await offMain { try ownership.tileKeys() }
    }

    private func bytes(_ keys: [String]) async throws -> Int64 {
        let cache = sandbox.cache
        return try await offMain { try cache.bytes(forKeys: keys) }
    }

    /// Tile indices on the fixture trail, so a tile is inside the corridor the
    /// auto-save store builds for it.
    private func tile(z: Int = 16, index: Int = 2) -> (z: Int, x: Int, y: Int) {
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[index]
        return (z, SlippyTileMath.tileX(anchor.longitude, z: z), SlippyTileMath.tileY(anchor.latitude, z: z))
    }

    private func key(_ tile: (z: Int, x: Int, y: Int)) -> String {
        TileCacheKey.namespaced(providerID: "osm", z: tile.z, x: tile.x, y: tile.y)
    }

    /// The tile thread's path: the tile has been drawn, so its bytes are in the
    /// browsing cache, and `considerPersisting` moves them if the hike wants
    /// them.
    private func persist(key: String, tile: (z: Int, x: Int, y: Int)) async throws {
        try sandbox.browse(key: key)
        let store = sandbox.store
        await offMain { store.considerPersisting(key: key, z: tile.z, x: tile.x, y: tile.y) }
    }

    // MARK: - Manifests

    @Test("a pre-change manifest is rewritten to the keys the renderer asks for")
    func manifestsAreRewritten() async throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.offlineDownloads = [
                OfflineDownloadRecord(
                    providerID: "osm",
                    maxZoom: 14,
                    savedTileKeys: ["osm/14/8723/5685@2.0"],
                    scale: 2
                ),
            ]
            hike.autoSavedTileKeys = ["osm/16/9/9@3.0"]
        }

        try migrate()

        #expect(hike.offlineDownloads.map(\.savedTileKeys) == [["osm/14/8723/5685"]])
        #expect(hike.offlineDownloads.map(\.scale) == [0])
        #expect(hike.autoSavedTileKeys == ["osm/16/9/9"])
        let claimed = try await claimedKeys(of: hike)
        #expect(claimed == ["osm/14/8723/5685", "osm/16/9/9"])
    }

    /// The whole point of the rewrite: the bytes stay, under the name the map
    /// now looks them up by. Deleting them instead would blank a map somebody
    /// downloaded for a valley with no signal.
    @Test("the tiles a pre-change manifest named are still on disk afterwards")
    func savedTilesAreRenamedRatherThanStranded() async throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = ["osm/16/9/9@2.0"]
        }
        try sandbox.save(key: "osm/16/9/9@2.0")

        try migrate()
        await settleDelegateHop(until: "the saved tile to be renamed") {
            sandbox.isSaved("osm/16/9/9")
        }

        #expect(!sandbox.isSaved("osm/16/9/9@2.0"), "the old name is one the renderer never asks for")
        #expect(hike.autoSavedTileKeys == ["osm/16/9/9"])
        #expect(try await bytes(["osm/16/9/9"]) > 0, "the hike's own sheet has to still count it")
    }

    /// A phone that downloaded at `@3.0` and browsed the same ground at `@2.0`
    /// holds two names for one tile. Only one of them can become the key they
    /// now share.
    @Test("two scales of one tile collapse to one key and one file")
    func duplicateScalesCollapse() async throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = ["osm/16/9/9@2.0", "osm/16/9/9@3.0"]
        }
        try sandbox.save(key: "osm/16/9/9@2.0")
        try sandbox.save(key: "osm/16/9/9@3.0")

        try migrate()
        await settleDelegateHop(until: "both legacy copies to be resolved to one") {
            sandbox.isSaved("osm/16/9/9")
                && !sandbox.isSaved("osm/16/9/9@2.0")
                && !sandbox.isSaved("osm/16/9/9@3.0")
        }

        #expect(hike.autoSavedTileKeys == ["osm/16/9/9"])
    }

    /// Records that differed only by the scale they were taken at describe one
    /// download now — the same rule a re-download follows, applied to what is
    /// already stored.
    @Test("download records that differed only by scale are folded together")
    func recordsTakenAtTwoScalesFold() throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.offlineDownloads = [
                OfflineDownloadRecord(
                    providerID: "osm",
                    maxZoom: 14,
                    savedTileKeys: ["osm/14/1/1@2.0"],
                    scale: 2
                ),
                OfflineDownloadRecord(
                    providerID: "osm",
                    maxZoom: 14,
                    savedTileKeys: ["osm/14/1/2@3.0"],
                    scale: 3
                ),
            ]
        }

        try migrate()

        #expect(hike.offlineDownloads.count == 1)
        #expect(hike.offlineDownloads.first?.savedTileKeys == ["osm/14/1/1", "osm/14/1/2"])
    }

    @Test("a complete record absorbs a partial one taken at another scale")
    func completeRecordAbsorbsPartial() throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.offlineDownloads = [
                OfflineDownloadRecord(providerID: "osm", maxZoom: 14, savedTileKeys: ["osm/14/1/1@2.0"], scale: 2),
                OfflineDownloadRecord(providerID: "osm", maxZoom: 14, scale: 3),
            ]
        }

        try migrate()

        #expect(hike.offlineDownloads.count == 1)
        #expect(
            hike.offlineDownloads.first?.savedTileKeys.isEmpty == true,
            "a complete download covers the whole grid, so narrowing it to one key would lose coverage"
        )
    }

    @Test("a manifest already in the current format is left exactly as it is")
    func currentManifestsAreUntouched() throws {
        let record = OfflineDownloadRecord(providerID: "osm", maxZoom: 14, savedTileKeys: ["osm/14/1/1"])
        let hike = Fixture.hike(in: context) { hike in
            hike.offlineDownloads = [record]
            hike.autoSavedTileKeys = ["osm/16/9/9"]
        }

        try migrate()
        try migrate()

        #expect(hike.offlineDownloads == [record])
        #expect(hike.autoSavedTileKeys == ["osm/16/9/9"])
    }

    // MARK: - Auto-save

    /// The functional dead end this migration exists to clear, as well as the
    /// accounting one. ``AutoSaveController`` seeds the store's dedupe set from
    /// the manifest and ``AutoSaveTileStore`` caps that set, so a hike whose
    /// cap was filled by two names for every tile could never save another —
    /// and none of the tiles it was holding could be drawn.
    @Test("a hike capped by two names for every tile can save again")
    func migrationFreesCapSlotsSpentOnDuplicates() async throws {
        let duplicated = (0..<(AutoSaveTileStore.tileCap / 2)).flatMap { index in
            ["osm/16/\(index)/9@2.0", "osm/16/\(index)/9@3.0"]
        }
        try #require(duplicated.count == AutoSaveTileStore.tileCap, "the manifest has to start at the cap")
        let hike = Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = duplicated
        }

        try migrate()
        #expect(hike.autoSavedTileKeys.count == AutoSaveTileStore.tileCap / 2)

        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()
        #expect(!controller.isCapReached(for: hike))

        let browsed = tile(z: 17)
        try await persist(key: key(browsed), tile: browsed)
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys.contains(key(browsed)))
    }

    /// The other half of the seeding: a tile the hike already owns must not be
    /// claimed a second time under its new name, or the cap is spent twice on
    /// it and the manifest grows on every browse.
    @Test("a migrated tile is recognised as one the hike already has")
    func migratedKeysAreStillKnownToTheStore() async throws {
        let browsed = tile()
        let hike = Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = ["\(key(browsed))@2.0"]
        }
        try sandbox.save(key: "\(key(browsed))@2.0")

        try migrate()
        await settleDelegateHop(until: "the saved tile to be renamed") {
            sandbox.isSaved(key(browsed))
        }

        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()
        try await persist(key: key(browsed), tile: browsed)
        controller.flushPendingKeys()

        #expect(hike.autoSavedTileKeys == [key(browsed)])
    }

    // MARK: - Refusals

    @Test("a manifest that cannot be saved keeps its keys and its files")
    func failedSaveMigratesNothing() async throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = ["osm/16/9/9@2.0"]
        }
        try sandbox.save(key: "osm/16/9/9@2.0")

        try migrate(saving: { throw ManifestSaveFailure() })
        await settleDelegateHop()

        #expect(
            hike.autoSavedTileKeys == ["osm/16/9/9@2.0"],
            "a rewrite that did not persist would claim keys with nothing behind them at the next launch"
        )
        #expect(sandbox.isSaved("osm/16/9/9@2.0"))
        #expect(!sandbox.isSaved("osm/16/9/9"))
    }

    @Test("a fetch that throws migrates nothing")
    func failedFetchMigratesNothing() async throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = ["osm/16/9/9@2.0"]
        }
        try sandbox.save(key: "osm/16/9/9@2.0")

        LegacyTileKeyMigration.run(
            cache: sandbox.cache,
            fetchingLocalStates: { throw ManifestSaveFailure() },
            saving: { try context.save() }
        )
        await settleDelegateHop()

        #expect(hike.autoSavedTileKeys == ["osm/16/9/9@2.0"])
        #expect(sandbox.isSaved("osm/16/9/9@2.0"))
    }

    // MARK: - The key itself

    @Test("only a trailing display scale is stripped from a key")
    func onlyDisplayScaleIsStripped() {
        #expect(TileCacheKey.withoutDisplayScale("osm/14/1/1@2.0") == "osm/14/1/1")
        #expect(TileCacheKey.withoutDisplayScale("osm/14/1/1@3.0") == "osm/14/1/1")
        #expect(TileCacheKey.withoutDisplayScale("osm/14/1/1") == "osm/14/1/1")
        #expect(
            TileCacheKey.withoutDisplayScale("stadia@key/14/1/1") == "stadia@key/14/1/1",
            "an @ before the last separator is part of the provider's namespace, not a scale"
        )
        #expect(
            TileCacheKey.withoutDisplayScale("osm/14/1/1@retina") == "osm/14/1/1@retina",
            "a suffix that is not a number was never a display scale"
        )
    }
}
