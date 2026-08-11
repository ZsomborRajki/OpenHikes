//
//  OfflineStorageAccountingTests.swift
//  OpenTrailsTests
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
import SwiftData
import Testing
@testable import OpenTrails

/// Nested inside `AutoSaveTests` to inherit its `.serialized` trait: these
/// drive the same single-active-hike singleton, and the store tests can't run
/// alongside them.
extension AutoSaveTests {

@MainActor
@Suite("Storage accounting")
struct StorageAccountingTests {
    private let store = AutoSaveTileStore.shared
    private let context: ModelContext
    /// Keys are namespaced per test run so nothing collides with a real
    /// cached tile — the tile's own z/x/y is passed separately anyway.
    private let namespace = "accounting-\(UUID().uuidString)"
    init() throws {
        context = try Fixture.modelContext()
        store.clearActiveHike()
    }

    // MARK: - Harness

    private func key(_ z: Int, _ x: Int, _ y: Int) -> String {
        "\(namespace)/\(z)/\(x)/\(y)@2.0"
    }

    /// Tile indices for a point on (or offset from) the fixture trail.
    private func tile(northMeters: Double = 0, z: Int = 16) -> (z: Int, x: Int, y: Int) {
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[2]
        let latitude = anchor.latitude + northMeters / 111_320
        return (z, SlippyTileMath.tileX(anchor.longitude, z: z), SlippyTileMath.tileY(latitude, z: z))
    }

    /// Runs the tile-thread path: the tile has been drawn, so its bytes are in
    /// the browsing cache, and `considerPersisting` moves them if the hike
    /// wants them.
    private func persist(key: String, tile: (z: Int, x: Int, y: Int)) async throws {
        try TileStore.browse(key: key)
        let store = store
        await offMain { store.considerPersisting(key: key, z: tile.z, x: tile.x, y: tile.y) }
    }

    private func bytes(_ keys: [String]) async -> Int64 {
        await offMain { TileCache.shared.bytes(forKeys: keys) }
    }

    /// What the hike sheets add up to: the tiles every hike's manifest claims.
    private func claimedKeys(of hikes: Hike...) async -> Set<String> {
        let ownerships = hikes.map(TileOwnership.init)
        return await offMain {
            ownerships.reduce(into: Set<String>()) { $0.formUnion($1.tileKeys()) }
        }
    }

    /// The two numbers Settings shows: offline coverage, and browsing residue.
    private func diskUsage(claimedBy keys: Set<String>) async -> TileCache.DiskUsage {
        await offMain { TileCache.shared.diskUsage(claimedBy: keys) }
    }

    /// The Clear Map Cache button. This really does empty the host app's tile
    /// store of everything `keys` doesn't name — which is the behaviour under
    /// test. Nothing else in the target keeps tile files across suites.
    private func clearMapCache(claimedBy keys: Set<String>) async {
        await offMain { TileCache.shared.removeTiles(unclaimedBy: keys) }
    }

    private func cleanUp(_ keys: [String]) async {
        await offMain { TileCache.shared.removeTiles(forKeys: keys) }
        store.clearActiveHike()
    }

    /// The delete-a-hike path from `MapSheet.delete(_:)`, minus the SwiftUI.
    private func deleteHike(_ hike: Hike, survivors: [Hike] = [], using controller: AutoSaveController) async {
        controller.hikeWillBeDeleted(hike)
        let deletionPlan = StoredTileDeletionPlan(removing: hike, among: [hike] + survivors)
        await offMain {
            TileCache.shared.removeTiles(forKeys: Array(deletionPlan.exclusiveTileKeys()))
        }
        context.delete(hike)
    }

    /// The Delete button in `HikeDetailView`, minus the SwiftUI.
    private func clearStoredTiles(
        for hike: Hike,
        among hikes: [Hike],
        using controller: AutoSaveController
    ) async {
        controller.setEnabled(false, for: hike)
        let deletionPlan = StoredTileDeletionPlan(removing: hike, among: hikes)
        hike.offlineDownloads.removeAll()
        hike.autoSavedTileKeys.removeAll()
        await offMain {
            TileCache.shared.removeTiles(forKeys: Array(deletionPlan.exclusiveTileKeys()))
        }
    }

    // MARK: - Coverage versus cache

    /// The baseline the rest of this suite is measured against: a tile
    /// auto-saved for the selected hike is offline coverage, and both screens
    /// say so.
    @Test("a tile saved for a hike is counted as coverage by that hike and by Settings")
    func savedTilesAreCountedByBoth() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 1, 1)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let claimed = await claimedKeys(of: hike)
        #expect(claimed.contains(saved))

        let hikeBytes = await bytes(Array(claimed))
        #expect(hikeBytes > 0, "the hike sheet should report the tile it just saved")

        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed == hikeBytes, "and Settings should report the same bytes back")

        await cleanUp([saved])
    }

    /// Issue 1, exactly: with one hike imported, the hike sheet said 11 MB and
    /// Settings said 17 MB. Both were right — panning past the corridor makes
    /// MapKit fetch tiles that `TileCache` writes and no manifest ever claims —
    /// but adding them into one "Downloaded tiles" figure presented browsing
    /// residue as deliberately saved data, and left the total permanently ahead
    /// of what the only hike could account for. Reported apart, the coverage
    /// number matches the hike sheet and the residue is named for what it is.
    @Test("browsing residue is reported as cache, not as offline coverage")
    func browsedTilesAreReportedAsCache() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 2, 2)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        // Panned ~25 km off the trail: drawn, cached, correctly not auto-saved.
        let browsed = key(16, 92, 92)
        try TileStore.browse(key: browsed)

        let claimed = await claimedKeys(of: hike)
        #expect(!claimed.contains(browsed), "auto-save rightly declines a tile this far off the trail")

        let claimedBytes = await bytes(Array(claimed))
        #expect(claimedBytes > 0, "precondition: the hike did save something")

        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed == claimedBytes, "the coverage number is exactly what the hikes claim")
        #expect(
            usage.unclaimed >= TileStore.tileByteCount,
            "and the browsed tile is counted in the cache number instead"
        )

        await cleanUp([saved, browsed])
    }

    /// Both offline routes write durably now, but the split still can't be
    /// made on storage tier. A download record claims a whole tile grid, and
    /// any of those tiles the user merely browsed — or downloaded on a build
    /// that cached them — sits in the ephemeral tier while being thoroughly
    /// spoken for. Bucketing by manifest is what keeps a cache clear off them.
    @Test("a claimed tile in the cache tier still counts as coverage")
    func claimedCacheTierTilesAreCoverage() async throws {
        let hike = Fixture.hike(in: context) {
            $0.offlineDownloads = [
                OfflineDownloadRecord(providerID: TileProvider.default.id, scale: 2, maxZoom: 12)
            ]
        }

        let claimed = await claimedKeys(of: hike)
        let downloaded = try #require(claimed.first)
        // A bulk download writes through `loadTile`, i.e. into the same place
        // browsing does.
        try TileStore.browse(key: downloaded)

        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed >= TileStore.tileByteCount, "the tile is coverage wherever it sits")

        await clearMapCache(claimedBy: claimed)
        #expect(await bytes([downloaded]) > 0, "and a cache clear must not touch it")

        await cleanUp([downloaded])
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
        try TileStore.browse(key: downloaded)

        // An unreachable URL: moving bytes that are already here needs no fetch.
        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(await TileCache.shared.saveTileDurably(forKey: downloaded, url: url))

        #expect(!TileStore.isBrowsed(downloaded), "the reclaimable copy is gone")
        #expect(await bytes([downloaded]) > 0, "and the tile is still saved")

        await cleanUp([downloaded])
    }

    /// Downloading an area auto-save already covered — or re-running a download
    /// — shouldn't cost the tile server a single request. Politeness towards
    /// OSM's usage policy, and the reason the two routes share a store.
    @Test("a tile already saved isn't fetched again")
    func alreadySavedTilesAreNotRefetched() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        // Auto-save put this one in durable storage while the map was browsed.
        let saved = key(16, 14, 14)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(
            await TileCache.shared.saveTileDurably(forKey: saved, url: url),
            "an unreachable URL is the proof that no request was made"
        )

        await cleanUp([saved])
    }

    /// Saving a tile moves the bytes the tile server sent, rather than
    /// re-encoding them into a second copy. Both tiers are searched under the
    /// same key, so a copy would cost the same bytes again and bill the hike
    /// for two of one tile — and a re-encode would either lose detail or, as
    /// measured on real tiles, take *more* space than the PNG it started from.
    @Test("auto-saving a tile moves it, byte for byte")
    func autoSaveMovesTheBrowsedCopy() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        // Drawn first — which is the only way auto-save ever sees a tile.
        let saved = key(16, 3, 3)
        try TileStore.browse(key: saved)
        #expect(await bytes([saved]) == TileStore.tileByteCount, "precondition: drawing it cached it")

        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        #expect(!TileStore.isBrowsed(saved), "the cached copy is gone, not duplicated")
        #expect(TileStore.isSaved(saved), "and it is what's now kept for offline use")
        #expect(
            await bytes([saved]) == TileStore.tileByteCount,
            "the same bytes, moved — no re-encode, so no size or quality change"
        )
        #expect(
            try Data(contentsOf: TileStore.savedFile(for: saved)) == TileStore.tileData,
            "and byte-identical to what the tile server sent"
        )

        await cleanUp([saved])
    }

    /// The other side of that trade: the copy left standing has to be the one
    /// that answers, or dropping the cached copy would have quietly cost the
    /// hike its offline coverage.
    @Test("a saved tile is still served once its browsed copy is gone")
    func durableCopyServesTheTile() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 11, 11)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        // An unreachable URL, so only a hit in durable storage can answer this.
        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(await TileCache.shared.loadTile(forKey: saved, url: url) != nil)

        await cleanUp([saved])
    }

    // MARK: - Deleting the hike leaves data behind

    @Test("deleting a hike frees the tiles it saved")
    func deletingFreesClaimedTiles() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 4, 4)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()
        #expect(await bytes([saved]) > 0, "precondition: the tile is on disk")

        await deleteHike(hike, using: controller)
        #expect(await bytes([saved]) == 0)
    }

    /// Issue 2: the hike was the only one in the app, and Settings still showed
    /// downloaded data after deleting it. Deletion is driven off the manifests,
    /// so it frees what the hike claimed and leaves what browsing put on disk
    /// without claiming — but with no hikes left, none of that is coverage any
    /// more, and it says so.
    @Test("deleting the only hike leaves no coverage, only clearable cache")
    func deletingTheOnlyHikeLeavesOnlyCache() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 5, 5)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let browsed = key(16, 93, 93)
        try TileStore.browse(key: browsed)

        await deleteHike(hike, using: controller)

        // What Settings computes with no hikes left to claim anything.
        let usage = await diskUsage(claimedBy: [])
        #expect(usage.claimed == 0, "nothing is being kept for offline use any more")
        #expect(await bytes([saved]) == 0, "the hike's own tiles went with it")
        #expect(await bytes([browsed]) == TileStore.tileByteCount, "its browsing residue is cache now")

        await cleanUp([browsed])
    }

    /// The other half of issue 2's fix: the residue is reclaimable on its own,
    /// without a hike having to be deleted and without touching the offline
    /// maps of the ones that remain.
    @Test("clearing the map cache frees the residue and keeps the coverage")
    func clearingTheCacheKeepsCoverage() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 12, 12)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()

        let browsed = key(16, 94, 94)
        try TileStore.browse(key: browsed)

        let claimed = await claimedKeys(of: hike)
        await clearMapCache(claimedBy: claimed)

        #expect(await bytes([saved]) > 0, "the hike's offline map survives")
        #expect(TileStore.isSaved(saved))
        #expect(await bytes([browsed]) == 0, "the browsing residue does not")
        #expect(!TileStore.isBrowsed(browsed))

        // Scoped to this hike's own keys on purpose: the suites in this target
        // run in parallel, so anything phrased as "nothing unclaimed is left on
        // disk" is a claim about a neighbour's tiles as much as about ours.
        let usage = await diskUsage(claimedBy: claimed)
        #expect(usage.claimed == (await bytes(Array(claimed))), "and its coverage is still counted as coverage")

        await cleanUp([saved])
    }

    // MARK: - Bounding the cache

    /// The map cache is the one thing here that grows without anyone asking:
    /// every tile MapKit draws is written, and until now nothing ever put a
    /// ceiling on that. A trim is what bounds it.
    @Test("browsing residue past the limit is trimmed back under it")
    func trimBringsCacheUnderTheLimit() async throws {
        let browsed = (0..<8).map { key(16, 20, $0) }
        for key in browsed { try TileStore.browse(key: key) }

        // A limit two tiles wide, so the trim has real work to do.
        let limit = TileStore.tileByteCount * 2
        let freed = await offMain { TileCache.shared.trimCache(claimedBy: [], limit: limit) }
        #expect(freed > 0)

        let remaining = await bytes(browsed)
        #expect(remaining <= limit, "the cache is back inside its bound")

        await cleanUp(browsed)
    }

    /// The bound is on the cache, not on offline maps. A hike's saved tiles are
    /// what the user has for a trail with no signal, so no size limit may take
    /// them — however old they are.
    @Test("a trim never takes offline coverage, however old")
    func trimSparesCoverage() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(16, 21, 0)
        try await persist(key: saved, tile: tile())
        controller.flushPendingKeys()
        // Older than anything else on disk, so a trim that could take it would.
        try TileStore.age(key: saved, byDays: 400)

        let browsed = (1..<6).map { key(16, 21, $0) }
        for key in browsed { try TileStore.browse(key: key) }

        let claimed = await claimedKeys(of: hike)
        let freed = await offMain {
            TileCache.shared.trimCache(claimedBy: claimed, limit: TileStore.tileByteCount)
        }
        #expect(freed > 0, "precondition: the trim did something")
        #expect(await bytes([saved]) > 0, "the hike's offline map is not the cache's to reclaim")
        #expect(TileStore.isSaved(saved))

        await cleanUp([saved] + browsed)
    }

    /// What goes is the ground the user has been away from longest — a tile
    /// fetched moments ago is the likeliest to be wanted again.
    @Test("the oldest tiles are the ones evicted")
    func trimEvictsOldestFirst() async throws {
        let stale = [key(16, 22, 0), key(16, 22, 1)]
        let fresh = [key(16, 22, 2), key(16, 22, 3)]
        for key in stale + fresh { try TileStore.browse(key: key) }
        for key in stale { try TileStore.age(key: key, byDays: 90) }

        // Four tiles on disk and room for three: the trim goes to 80% of the
        // limit rather than sitting exactly on it, so it takes two — which is
        // enough to see *which* two.
        _ = await offMain {
            TileCache.shared.trimCache(claimedBy: [], limit: TileStore.tileByteCount * 3)
        }

        #expect(stale.allSatisfy { !TileStore.isBrowsed($0) }, "the 90-day-old tiles go")
        #expect(fresh.allSatisfy(TileStore.isBrowsed), "the ones just fetched stay")

        await cleanUp(stale + fresh)
    }

    /// Housekeeping runs on every launch, so the common case — a cache well
    /// inside its bound — has to cost nothing and delete nothing.
    @Test("a cache under the limit is left alone")
    func trimBelowLimitIsANoOp() async throws {
        let browsed = (0..<3).map { key(16, 23, $0) }
        for key in browsed { try TileStore.browse(key: key) }

        let freed = await offMain {
            TileCache.shared.trimCache(claimedBy: [], limit: TileCache.cacheByteLimit)
        }
        #expect(freed == 0)
        #expect(browsed.allSatisfy(TileStore.isBrowsed))

        await cleanUp(browsed)
    }

    // MARK: - Expiration

    @Test("launch cleanup removes tiles after seven days from both disk tiers")
    func launchCleanupRemovesExpiredTiles() async throws {
        let staleBrowsed = key(16, 24, 0)
        let staleSaved = key(16, 24, 1)
        let freshBrowsed = key(16, 24, 2)
        try TileStore.browse(key: staleBrowsed)
        try TileStore.browse(key: staleSaved)
        try TileStore.browse(key: freshBrowsed)
        #expect(await offMain { TileCache.shared.promoteCachedTile(forKey: staleSaved) })
        try TileStore.age(key: staleBrowsed, byDays: 8)
        try TileStore.age(key: staleSaved, byDays: 8)

        let removed = await offMain { TileCache.shared.removeExpiredTiles() }

        #expect(removed >= 2)
        #expect(!TileStore.isBrowsed(staleBrowsed))
        #expect(!TileStore.isSaved(staleSaved))
        #expect(TileStore.isBrowsed(freshBrowsed), "tiles inside the seven-day TTL remain cached")
        await cleanUp([staleBrowsed, staleSaved, freshBrowsed])
    }

    @Test("an expired tile is deleted instead of being displayed")
    func displayLookupRejectsExpiredTile() async throws {
        let stale = key(16, 25, 0)
        try TileStore.browse(key: stale)
        try TileStore.age(key: stale, byDays: 8)
        let unavailableURL = try #require(URL(string: "file:///expired-tile-must-not-load"))

        let image = await TileCache.shared.loadTile(forKey: stale, url: unavailableURL)

        #expect(image == nil)
        #expect(!TileStore.isBrowsed(stale))
        await cleanUp([stale])
    }

    // MARK: - Tiles auto-save writes but forgets

    /// A tile is durable on disk the moment it's saved, but only enters the
    /// hike's manifest at the next 2-second drain. Tearing the store's active
    /// hike down in between discards the pending set, and with it the only
    /// record that those bytes belong to anything — they are then invisible
    /// to the hike's size, to its Delete button, and to deleting the hike.
    @Test("deselecting a hike keeps the tiles it just saved accounted for")
    func deselectingFoldsInPendingKeys() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(17, 6, 6)
        try await persist(key: saved, tile: tile(z: 17))
        // No flush: the drain timer hasn't come round yet.
        controller.hikeSelectionChanged(to: nil)

        #expect(await bytes([saved]) > 0, "precondition: the tile is durably on disk")
        #expect(hike.autoSavedTileKeys.contains(saved), "otherwise nothing will ever free it")

        await cleanUp([saved])
    }

    @Test("switching hikes keeps the outgoing hike's newest tiles accounted for")
    func switchingHikesFoldsInPendingKeys() async throws {
        let controller = AutoSaveController()
        let first = Fixture.hike(in: context)
        let second = Fixture.hike(title: "Second", route: Fixture.loopRoute, in: context)
        controller.hikeSelectionChanged(to: first)

        let saved = key(17, 7, 7)
        try await persist(key: saved, tile: tile(z: 17))
        controller.hikeSelectionChanged(to: second)

        #expect(first.autoSavedTileKeys.contains(saved))
        #expect(!second.autoSavedTileKeys.contains(saved), "the tile belongs to the trail it was saved for")

        await cleanUp([saved])
    }

    @Test("turning auto-save off keeps what it already saved accounted for")
    func disablingFoldsInPendingKeys() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(17, 8, 8)
        try await persist(key: saved, tile: tile(z: 17))
        controller.setEnabled(false, for: hike)

        #expect(hike.autoSavedTileKeys.contains(saved))
        await cleanUp([saved])
    }

    /// Deleting the hike the user is looking at is the case where the pending
    /// window matters most: those tiles are durable, so nothing — not iOS
    /// storage pressure, not a later delete — will ever reclaim them.
    @Test("deleting a hike frees even the tiles it saved a moment ago")
    func deletingFreesPendingTiles() async throws {
        let controller = AutoSaveController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)

        let saved = key(17, 9, 9)
        try await persist(key: saved, tile: tile(z: 17))
        #expect(await bytes([saved]) > 0, "precondition: the tile is durably on disk")

        // No flush first: the delete path is responsible for that itself.
        await deleteHike(hike, using: controller)
        #expect(await bytes([saved]) == 0)
    }

    /// The flush a delete performs must not hand one trail's tiles to
    /// another: a tile saved for the doomed hike is still shared coverage if a
    /// surviving hike's own manifest claims it.
    @Test("a surviving hike's tiles are not freed by deleting another")
    func deletingKeepsSharedTiles() async throws {
        let controller = AutoSaveController()
        let doomed = Fixture.hike(in: context)
        let survivor = Fixture.hike(title: "Survivor", in: context)
        controller.hikeSelectionChanged(to: doomed)

        let shared = key(17, 10, 10)
        try await persist(key: shared, tile: tile(z: 17))
        controller.flushPendingKeys()
        survivor.autoSavedTileKeys = [shared]

        await deleteHike(doomed, survivors: [survivor], using: controller)
        #expect(await bytes([shared]) > 0, "the surviving hike still lists this tile")

        await cleanUp([shared])
    }

    @Test("clearing one hike's offline tiles keeps another hike's shared coverage")
    func clearingStoredTilesKeepsSharedTiles() async throws {
        let controller = AutoSaveController()
        let cleared = Fixture.hike(title: "Cleared", in: context)
        let survivor = Fixture.hike(title: "Survivor", in: context)
        controller.hikeSelectionChanged(to: cleared)

        let shared = key(17, 11, 11)
        try await persist(key: shared, tile: tile(z: 17))
        controller.flushPendingKeys()
        survivor.autoSavedTileKeys = [shared]

        await clearStoredTiles(for: cleared, among: [cleared, survivor], using: controller)

        #expect(cleared.autoSavedTileKeys.isEmpty)
        #expect(cleared.offlineDownloads.isEmpty)
        #expect(survivor.autoSavedTileKeys == [shared])
        #expect(await bytes([shared]) > 0, "the surviving hike still owns this tile")

        await cleanUp([shared])
    }
}

}
