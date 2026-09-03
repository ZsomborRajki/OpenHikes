//
//  OfflineStorageAccountingTests.swift
//  OpenHikesTests
//
//  Two screens report tile bytes: "Offline tiles · N MB" on a hike's detail
//  sheet, and Settings. They are computed from opposite directions — the hike
//  sums the tiles its manifest *claims*, Settings sums the tiles actually *on
//  disk* — so every tile on disk that no manifest claims sits between them.
//  Every tile MapKit draws is written to disk, claimed or not, so there is
//  always a lot of it.
//
//  Settings therefore reports two numbers, split by whether a manifest claims
//  the tile: coverage, which has to equal what the hike sheets add up to and
//  has to survive a cache clear, and residue, which must not be presented as
//  something the user chose to download. These pin that split down — plus the
//  tiles auto-save writes but drops the record of, which land on the wrong
//  side of it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Storage accounting")
struct StorageAccountingTests {
    /// This suite's own tile directories and its own auto-save store, so it
    /// neither sees nor disturbs any other suite's tiles.
    let sandbox = TileSandbox()
    let context: ModelContext

    var store: AutoSaveTileStore { sandbox.store }

    init() throws {
        context = try Fixture.modelContext()
    }

    /// A controller wired to this suite's store rather than the app's.
    func makeController() -> AutoSaveController {
        AutoSaveController(store: sandbox.store, drainInterval: nil)
    }

    // MARK: - Harness

    func key(_ z: Int, _ x: Int, _ y: Int) -> String {
        "\(z)/\(x)/\(y)@2.0"
    }

    /// Tile indices for a point on (or offset from) the fixture trail.
    func tile(northMeters: Double = 0, z: Int = 16) -> (z: Int, x: Int, y: Int) {
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[2]
        let latitude = anchor.latitude + northMeters / 111_320
        return (z, SlippyTileMath.tileX(anchor.longitude, z: z), SlippyTileMath.tileY(latitude, z: z))
    }

    /// Runs the tile-thread path: the tile has been drawn, so its bytes are in
    /// the browsing cache, and `considerPersisting` moves them if the hike
    /// wants them.
    func persist(key: String, tile: (z: Int, x: Int, y: Int)) async throws {
        try sandbox.browse(key: key)
        let autoSaveStore = store
        await offMain { autoSaveStore.considerPersisting(key: key, z: tile.z, x: tile.x, y: tile.y) }
    }

    func bytes(_ keys: [String]) async throws -> Int64 {
        let cache = sandbox.cache
        return try await offMain { try cache.bytes(forKeys: keys) }
    }

    /// What the hike sheets add up to: the tiles every hike's manifest claims.
    func claimedKeys(of hikes: Hike...) async throws -> Set<String> {
        let ownerships = hikes.map(TileOwnership.init)
        return try await offMain {
            var keys = Set<String>()
            for ownership in ownerships {
                keys.formUnion(try ownership.tileKeys())
            }
            return keys
        }
    }

    /// The two numbers Settings shows: offline coverage, and browsing residue.
    func diskUsage(claimedBy keys: Set<String>) async -> TileCache.DiskUsage {
        let cache = sandbox.cache
        return await offMain { cache.diskUsage(claimedBy: keys) }
    }

    /// The Clear Map Cache button, run against this suite's own cache: it
    /// really does delete everything `keys` doesn't name.
    func clearMapCache(claimedBy keys: Set<String>) async {
        let cache = sandbox.cache
        await offMain { cache.removeTiles(unclaimedBy: keys) }
    }

    /// "Delete All Saved Tiles" in Settings.
    func removeAllTiles() async {
        let cache = sandbox.cache
        await offMain { cache.removeAllTiles() }
    }

    /// The launch-time sweeps, run on demand.
    func trim(claimedBy keys: Set<String>, limit: Int64) async -> Int64 {
        let cache = sandbox.cache
        return await offMain { cache.trimCache(claimedBy: keys, limit: limit) }
    }

    func removeExpiredTiles() async -> Int {
        let cache = sandbox.cache
        return await offMain { cache.removeExpiredTiles() }
    }

    func promoteCachedTile(forKey key: String) async -> Bool {
        let cache = sandbox.cache
        return await offMain { cache.promoteCachedTile(forKey: key) }
    }

    @Test("partial and complete records enumerate their exact union")
    func partialAndCompleteRecordsUnion() async throws {
        let route = Fixture.coordinates(Fixture.ridgeRoute)
        let provider = TileProvider.default
        let fullRecord = OfflineDownloadRecord(
            providerID: provider.id,
            maxZoom: 12
        )
        let fullKeys = Set(
            OfflineTileDownloader.tileKeys(
                for: route,
                providerID: provider.id,
                providerMaxZoom: provider.maximumZ,
                maxZoom: 12
            )
        )
        let overlap = try #require(fullKeys.first)
        let extra = "\(provider.id)/13/999/999@2.0"
        let partialRecord = OfflineDownloadRecord(
            providerID: provider.id,
            maxZoom: 12,
            savedTileKeys: [overlap, extra]
        )

        let stored = try await offMain {
            Set(
                try OfflineTileDownloader.storedTileKeys(
                    route: route,
                    offlineDownloads: [partialRecord, fullRecord]
                )
            )
        }

        #expect(stored == fullKeys.union([extra]))
    }

    /// The delete-a-hike path from `MapSheet.delete(_:among:)`, minus the SwiftUI.
    func deleteHike(_ hike: Hike, using controller: AutoSaveController, survivors: [Hike] = []) async throws {
        controller.hikeWillBeDeleted(hike)
        let deletionPlan = try #require(StoredTileDeletionPlan(removing: hike, among: [hike] + survivors))
        await deletionPlan.removeExclusiveTiles(from: sandbox.cache)
        context.delete(hike)
    }

    /// The Delete button in `HikeDetailView`, minus the SwiftUI.
    func clearStoredTiles(
        for hike: Hike,
        among hikes: [Hike],
        using controller: AutoSaveController
    ) async throws {
        controller.setEnabled(false, for: hike)
        let deletionPlan = try #require(StoredTileDeletionPlan(removing: hike, among: hikes))
        hike.offlineDownloads.removeAll()
        hike.autoSavedTileKeys.removeAll()
        await deletionPlan.removeExclusiveTiles(from: sandbox.cache)
    }

    // MARK: - Coverage versus cache

    /// The baseline the rest of this suite is measured against: a tile
    /// auto-saved for the selected hike is offline coverage, and both screens
    /// say so.
    @Test("a tile saved for a hike is counted as coverage by that hike and by Settings")
    func savedTilesAreCountedByBoth() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(16, 1, 1)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let claimed = try await claimedKeys(of: hike)
        #expect(claimed.contains(saved))

        let hikeBytes = try await bytes(Array(claimed))
        #expect(hikeBytes > 0, "the hike sheet should report the tile it just saved")

        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed == hikeBytes, "and Settings should report the same bytes back")
    }

    /// Why the two numbers are reported apart. Panning past the corridor makes
    /// MapKit fetch tiles that `TileCache` writes and no manifest ever claims,
    /// so a single "Downloaded tiles" figure would present browsing residue as
    /// deliberately saved data and sit permanently ahead of what the hikes can
    /// account for. Split, the coverage number matches the hike sheet and the
    /// residue is named for what it is.
    @Test("browsing residue is reported as cache, not as offline coverage")
    func browsedTilesAreReportedAsCache() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(16, 2, 2)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        // A tile far off the trail: drawn and cached, never claimed.
        let browsed = key(16, 92, 92)
        try sandbox.browse(key: browsed)

        let claimed = try await claimedKeys(of: hike)
        #expect(!claimed.contains(browsed), "auto-save rightly declines a tile this far off the trail")

        let claimedBytes = try await bytes(Array(claimed))
        #expect(claimedBytes > 0, "precondition: the hike did save something")

        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed == claimedBytes, "the coverage number is exactly what the hikes claim")
        #expect(
            usage.unclaimed >= TileStore.tileByteCount,
            "and the browsed tile is counted in the cache number instead"
        )
    }

    /// Both offline routes write durably now, but the split still can't be
    /// made on storage tier. A download record claims a whole tile grid, and
    /// any of those tiles the user merely browsed — or downloaded on a build
    /// that cached them — sits in the ephemeral tier while being thoroughly
    /// spoken for. Bucketing by manifest is what keeps a cache clear off them.
    @Test("a claimed tile in the cache tier still counts as coverage")
    func claimedCacheTierTilesAreCoverage() async throws {
        let hike = Fixture.hike(in: context) { hike in
            hike.offlineDownloads = [
                OfflineDownloadRecord(providerID: TileProvider.default.id, maxZoom: 12)
            ]
        }

        let claimed = try await claimedKeys(of: hike)
        let downloaded = try #require(claimed.first)
        // The user merely browsed this one, so it sits in the ephemeral tier
        // while a download record claims it.
        try sandbox.browse(key: downloaded)

        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed >= TileStore.tileByteCount, "the tile is coverage wherever it sits")

        await clearMapCache(claimedBy: claimed)
        #expect(try await bytes([downloaded]) > 0, "and a cache clear must not touch it")
    }

    // MARK: - Where each route puts its tiles

    /// The two ways a tile becomes offline coverage — auto-save while browsing,
    /// and a bulk download — now agree on where the bytes go. A download's
    /// whole purpose is tiles that are there when the signal isn't, so they
    /// can't sit in the tier the OS reclaims first.
    @Test("a downloaded tile is stored where the OS can't reclaim it")
    func downloadsAreStoredDurably() async throws {
        let downloaded = key(16, 13, 13)
        // Drawn earlier, so the bytes are already on disk — in the wrong tier.
        try sandbox.browse(key: downloaded)

        // An unreachable URL: moving bytes that are already here needs no fetch.
        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(await sandbox.cache.saveTileDurably(forKey: downloaded, url: url))

        #expect(!sandbox.isBrowsed(downloaded), "the reclaimable copy is gone")
        #expect(try await bytes([downloaded]) > 0, "and the tile is still saved")
    }

    /// Downloading an area auto-save already covered — or re-running a download
    /// — shouldn't cost the tile server a single request. Politeness towards
    /// OSM's usage policy, and the reason the two routes share a store.
    @Test("a tile already saved isn't fetched again")
    func alreadySavedTilesAreNotRefetched() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        // Auto-save put this one in durable storage while the map was browsed.
        let saved = key(16, 14, 14)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(
            await sandbox.cache.saveTileDurably(forKey: saved, url: url),
            "an unreachable URL is the proof that no request was made"
        )
    }

    /// Saving a tile moves the bytes the tile server sent, rather than
    /// re-encoding them into a second copy. Both tiers are searched under the
    /// same key, so a copy would cost the same bytes again and bill the hike
    /// for two of one tile — and a re-encode would either lose detail or, as
    /// measured on real tiles, take *more* space than the PNG it started from.
    @Test("auto-saving a tile moves it, byte for byte")
    func autoSaveMovesTheBrowsedCopy() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        // Drawn first — which is the only way auto-save ever sees a tile.
        let saved = key(16, 3, 3)
        try sandbox.browse(key: saved)
        #expect(try await bytes([saved]) == TileStore.tileByteCount, "precondition: drawing it cached it")

        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        #expect(!sandbox.isBrowsed(saved), "the cached copy is gone, not duplicated")
        #expect(sandbox.isSaved(saved), "and it is what's now kept for offline use")
        #expect(
            try await bytes([saved]) == TileStore.tileByteCount,
            "the same bytes, moved — no re-encode, so no size or quality change"
        )
        #expect(
            try Data(contentsOf: sandbox.savedFile(for: saved)) == TileStore.tileData,
            "and byte-identical to what the tile server sent"
        )
    }

    /// The other side of that trade: the copy left standing has to be the one
    /// that answers, or dropping the cached copy would have quietly cost the
    /// hike its offline coverage.
    @Test("a saved tile is still served once its browsed copy is gone")
    func durableCopyServesTheTile() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(16, 11, 11)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        // An unreachable URL, so only a hit in durable storage can answer this.
        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(await sandbox.cache.loadTile(forKey: saved, url: url) != nil)
    }

    // MARK: - Deleting the hike leaves data behind

    @Test("deleting a hike frees the tiles it saved")
    func deletingFreesClaimedTiles() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(16, 4, 4)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()
        #expect(try await bytes([saved]) > 0, "precondition: the tile is on disk")

        try await deleteHike(hike, using: controller)
        #expect(try await bytes([saved]) == 0)
    }

    /// Deletion is driven off the manifests, so it frees what the hike claimed
    /// and leaves what browsing put on disk without claiming — but with no
    /// hikes left, none of that is coverage any more, and Settings says so.
    @Test("deleting the only hike leaves no coverage, only clearable cache")
    func deletingTheOnlyHikeLeavesOnlyCache() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(16, 5, 5)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let browsed = key(16, 93, 93)
        try sandbox.browse(key: browsed)

        try await deleteHike(hike, using: controller)

        // What Settings computes with no hikes left to claim anything.
        let usage = await diskUsage(claimedBy: [])
        #expect(usage.claimed == 0, "nothing is being kept for offline use any more")
        #expect(try await bytes([saved]) == 0, "the hike's own tiles went with it")
        #expect(try await bytes([browsed]) == TileStore.tileByteCount, "its browsing residue is cache now")
    }

    /// The residue is reclaimable on its own, without a hike having to be
    /// deleted and without touching the offline maps of the ones that remain.
    @Test("clearing the map cache frees the residue and keeps the coverage")
    func clearingTheCacheKeepsCoverage() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let saved = key(16, 12, 12)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let browsed = key(16, 94, 94)
        try sandbox.browse(key: browsed)

        let claimed = try await claimedKeys(of: hike)
        await clearMapCache(claimedBy: claimed)

        #expect(try await bytes([saved]) > 0, "the hike's offline map survives")
        #expect(sandbox.isSaved(saved))
        #expect(try await bytes([browsed]) == 0, "the browsing residue does not")
        #expect(!sandbox.isBrowsed(browsed))

        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed == (try await bytes(Array(claimed))), "and its coverage is still counted as coverage")
    }

}
