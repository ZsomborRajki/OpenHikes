//
//  TileCacheTierTests.swift
//  OpenHikesTests
//
//  `TileCache` keeps the same tile under the same file name in two
//  directories — `Caches/OSMTiles` (browsing, OS-reclaimable) and
//  `Application Support/OSMTilesSaved` (offline coverage). The rest of the
//  suite treats those tiers as mutually exclusive, and the cache's job is to
//  make that true: **one key, at most one file.**
//
//  It isn't automatic. The two writers reach the disk through different entry
//  points — the map's renderer through `loadTile`, the bulk downloader through
//  `saveTileDurably` — and file their bytes in different directories. These
//  tests pin the invariant from both ends: that no write path leaves two
//  files, and that no read path counts one key twice. Plus the one memory-tier
//  behaviour the launch path depends on.
//

import Foundation
@testable import OpenHikes
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@Suite("Tile cache tiers")
struct TileCacheTierTests {
    /// Its own directory pair: these write into — and, through
    /// `removeExpiredTiles()`, delete across — both tiers wholesale, which is
    /// exactly the operation that used to make them unsafe to run beside
    /// anything else.
    private let sandbox = TileSandbox()

    private func makeKey(_ suffix: String = UUID().uuidString) -> String {
        "tiertest-\(suffix)/12/2200/1400@2.0"
    }

    /// Puts the same bytes in both tiers — the state an install carries
    /// forward from a build whose write paths didn't reconcile them.
    private func writeBothTiers(_ key: String) throws {
        try sandbox.browse(key: key)
        try sandbox.save(key: key)
    }

    /// The cache operations, run off the main thread as the pipeline demands.
    private func promoteCachedTile(forKey key: String) async -> Bool {
        let cache = sandbox.cache
        return await offMain { cache.promoteCachedTile(forKey: key) }
    }

    private func bytes(forKeys keys: [String]) async throws -> Int64 {
        let cache = sandbox.cache
        return try await offMain { try cache.bytes(forKeys: keys) }
    }

    private func diskUsage(claimedBy keys: Set<String>) async -> TileCache.DiskUsage {
        let cache = sandbox.cache
        return await offMain { cache.diskUsage(claimedBy: keys) }
    }

    private func removeExpiredTiles() async -> Int {
        let cache = sandbox.cache
        return await offMain { cache.removeExpiredTiles() }
    }

    private func trimCache(claimedBy keys: Set<String>, limit: Int64) async -> Int64 {
        let cache = sandbox.cache
        return await offMain { cache.trimCache(claimedBy: keys, limit: limit) }
    }

    @Test("tile requests bypass Foundation's URL cache")
    func tileSessionDisablesURLCache() {
        let injected = URLSessionConfiguration.default
        injected.urlCache = .shared

        let configured = TileCache.tileSessionConfiguration(from: injected)

        #expect(configured.urlCache == nil)
        #expect(
            configured.requestCachePolicy
                == .reloadIgnoringLocalCacheData
        )
    }

    /// `promoteCachedTile` is where a tile found in both tiers is reconciled:
    /// it notices the durable copy, returns `true`, and drops the redundant
    /// ephemeral one instead of leaving the tile occupying two files for the
    /// rest of its seven-day life. That was pure waste on the one axis this app
    /// is careful about everywhere else, and it inflated the residue figure
    /// that `trimCache` then worked to bring back down.
    @Test("promoting a tile that's already saved reclaims the redundant copy")
    func promotionReclaimsTheEphemeralDuplicate() async throws {
        let key = makeKey()
        try writeBothTiers(key)

        let promoted = await promoteCachedTile(forKey: key)
        #expect(promoted, "precondition: the tile counts as durably saved")
        #expect(sandbox.isSaved(key))
        #expect(!sandbox.isBrowsed(key), "one tile should not sit in two directories")
    }

    /// The same reconciliation one instruction later. Two threads drawing the
    /// same tile both reach `promoteCachedTile`, and the loser can arrive
    /// between the two tier checks: it saw no durable copy, and by the time it
    /// looks for the cached one the winner's move has taken it. Answering
    /// "not saved" there is a lie the caller acts on — ``AutoSaveTileStore``
    /// hands back a claim whose bytes are on disk, so the hike stops owning a
    /// tile that is saved, and nothing reconsiders it because the browsing
    /// copy it would be re-saved from is the file that moved. A stochastic
    /// concurrency test found this once in CI; the seam pins it every run.
    @Test("a promotion overtaken mid-check still reports the tile saved")
    func promotionOvertakenByAnotherWriterReportsSaved() async throws {
        let key = makeKey()
        try sandbox.browse(key: key)
        let tiles = sandbox

        let promoted = await offMain {
            tiles.cache.promoteCachedTile(forKey: key) {
                // Exactly what the winning writer's move leaves behind: the
                // bytes durable, the browsing copy gone.
                try? tiles.save(key: key)
                try? FileManager.default.removeItem(at: tiles.browsedFile(for: key))
            }
        }

        #expect(promoted, "the tile is durably stored, whichever call moved it")
        #expect(sandbox.isSaved(key))
        #expect(!sandbox.isBrowsed(key))
    }

    /// What that duplication did to the number the user reads. The hike sheet
    /// measures its offline coverage with `bytes(forKeys:)`, which takes one
    /// tier per key — summing both would bill a duplicated tile twice.
    @Test("a duplicated tile isn't reported as twice the coverage")
    func bytesDoesNotDoubleCountAcrossTiers() async throws {
        let key = makeKey()
        try writeBothTiers(key)

        let measured = try await bytes(forKeys: [key])
        #expect(measured == TileStore.tileByteCount)
    }

    /// The same double-count, on the screen that reports it app-wide. Settings
    /// enumerates both directories, so a duplicate showed up as two files there
    /// too — inflating whichever of "Saved for offline" or "Map cache" the key
    /// fell into.
    @Test("a duplicated tile is measured once by Settings")
    func diskUsageDoesNotDoubleCountAcrossTiers() async throws {
        let key = makeKey()
        try writeBothTiers(key)

        let claimed = await diskUsage(claimedBy: [key])
        #expect(claimed.claimed == TileStore.tileByteCount, "counted once as coverage")

        let unclaimed = await diskUsage(claimedBy: [])
        #expect(
            unclaimed.unclaimed >= TileStore.tileByteCount,
            "and once as cache when nothing claims it"
        )
        #expect(
            unclaimed.unclaimed - (await diskUsage(claimedBy: [key])).unclaimed
                == TileStore.tileByteCount,
            "the key accounts for exactly one tile's worth either way"
        )
    }

    /// The write path that produced the duplicates in the first place: a
    /// download saving a tile the map has already fetched into the browsing
    /// tier. The bytes are identical, so the only question is how many files
    /// are left holding them.
    @Test("saving a tile durably doesn't leave the browsed copy behind")
    func durableSaveReclaimsTheBrowsedCopy() async throws {
        let key = makeKey()
        try sandbox.browse(key: key)

        // An unreachable URL: a tile already on disk needs no fetch.
        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(await sandbox.cache.saveTileDurably(forKey: key, url: url))

        #expect(sandbox.isSaved(key))
        #expect(!sandbox.isBrowsed(key), "the browsing-tier copy is gone, not duplicated")
        #expect(try await bytes(forKeys: [key]) == TileStore.tileByteCount)
    }

    /// An expired tile is deleted where it lies and refetched. If the refetch
    /// always wrote to the browsing tier, a tile a hike is keeping offline
    /// would come back as OS-reclaimable cache — still claimed by the manifest,
    /// but no longer actually durable.
    @Test("refetching an expired tile keeps it in the tier it was in")
    func refetchPreservesTheDurableTier() async throws {
        let key = makeKey()

        // Durably saved, then aged past the seven-day TTL.
        try writeBothTiers(key)
        try? FileManager.default.removeItem(at: sandbox.browsedFile(for: key))
        try sandbox.age(key: key, byDays: 8)

        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        _ = await sandbox.cache.loadTile(forKey: key, url: url)

        // The fetch fails (unreachable), so what's pinned here is that nothing
        // was written to the browsing tier in the expired tile's place.
        #expect(!sandbox.isBrowsed(key), "an expired durable tile must not reappear as cache")
    }

    /// Installs that already have duplicates from earlier builds heal at the
    /// next launch rather than carrying them for another seven days.
    @Test("launch housekeeping reclaims duplicates left by earlier builds")
    func expiryPassReclaimsDuplicates() async throws {
        let key = makeKey()
        try writeBothTiers(key)

        let removed = await removeExpiredTiles()
        #expect(removed >= 1)
        #expect(sandbox.isSaved(key), "the durable copy is the one that's kept")
        #expect(!sandbox.isBrowsed(key))
    }

    /// `OpenHikesApp.init` kicks off `removeExpiredTiles()` on the maintenance queue
    /// at every launch. It used to empty the memory cache before it looked at a
    /// single date — including tiles the map populated in the milliseconds
    /// since launch, which are by definition the ones on screen — and every one
    /// of them was then re-read from disk on the next draw pass, at exactly the
    /// moment the app is busiest.
    ///
    /// Only *expired* tiles need to go, and `memoryImage(forKey:)` already
    /// rejects those lazily on read.
    @Test("launch housekeeping doesn't evict tiles that haven't expired")
    func expiryPassKeepsFreshMemoryTiles() async throws {
        let key = makeKey()
        try sandbox.browse(key: key)

        // A disk read is what populates the memory tier — no network involved.
        let loaded = await sandbox.cache.loadTile(forKey: key, url: URL(string: "http://127.0.0.1:9/x.png")!)
        try #require(loaded != nil, "precondition: the tile is cached in memory")
        try #require(sandbox.cache.memoryImage(forKey: key) != nil)

        let removed = await removeExpiredTiles()
        #expect(removed == 0, "the tile is fresh, so nothing should have been deleted from disk")
        #expect(sandbox.isBrowsed(key), "and it's still on disk")
        #expect(
            sandbox.cache.memoryImage(forKey: key) != nil,
            "a fresh tile shouldn't have to be read back off disk because an unrelated one expired"
        )
    }

    @Test("cache maintenance stays off the physical main thread")
    @MainActor
    func maintenanceRunsOffMain() async {
        let ranOffMain = await TileCache.performMaintenance {
            !Thread.isMainThread
        }
        #expect(ranOffMain)
    }

    /// The other launch-time sweep, with the same reasoning: `trimCache` runs
    /// from `OpenHikesModel` on every launch, and a tile it leaves on disk must
    /// still be in memory afterwards. (An over-the-limit trim is what makes
    /// this reachable at all — under the limit it returns before touching
    /// anything, which is why there is a second, unclaimed tile here to put the
    /// sweep over its limit.)
    @Test("a cache trim doesn't evict tiles it decided to keep")
    func trimKeepsFreshMemoryTiles() async throws {
        let kept = makeKey()
        let residue = makeKey()
        try sandbox.browse(key: kept)
        try sandbox.browse(key: residue)

        let loaded = await sandbox.cache.loadTile(forKey: kept, url: URL(string: "http://127.0.0.1:9/x.png")!)
        try #require(loaded != nil, "precondition: the tile is cached in memory")

        // Claimed, so the trim can't delete it however far over the limit we are.
        let freed = await trimCache(claimedBy: [kept], limit: 0)
        #expect(
            freed == TileStore.tileByteCount,
            "the unclaimed tile is the only one the trim may count, so it is the whole reclaim"
        )
        #expect(!sandbox.isBrowsed(residue), "precondition: the trim really did delete something")
        #expect(sandbox.isBrowsed(kept), "precondition: a claimed tile survives the trim")
        #expect(
            sandbox.cache.memoryImage(forKey: kept) != nil,
            "a tile the trim kept on disk shouldn't be dropped from memory by it"
        )
    }

    /// What an empty claim set costs, which is why the caller must never
    /// produce one by accident. `trimCache` distinguishes a claimed tile from
    /// an unclaimed one by nothing but that set, so an empty one makes a
    /// durably saved tile — a hike's offline map, the thing this app exists to
    /// have when there is no signal — indistinguishable from browsing residue.
    /// This is the consequence side of the rule
    /// `OpenHikesModel.trimTileCache(in:)` keeps: a failed `Hike` fetch, or a
    /// cancelled claim enumeration, returns without trimming rather than
    /// trimming against an empty set.
    @Test("an empty claim set deletes saved offline tiles, not just residue")
    func trimWithNoClaimsEvictsDurableTiles() async throws {
        let saved = makeKey()
        try sandbox.save(key: saved)
        try #require(sandbox.isSaved(saved), "precondition: the tile is durably saved")

        let freed = await trimCache(claimedBy: [], limit: 0)

        #expect(freed >= TileStore.tileByteCount)
        #expect(
            !sandbox.isSaved(saved),
            "an unclaimed durable tile is evicted, so an empty claim set is destructive"
        )
    }

    /// The half of the same pass that must keep working: an expired tile is
    /// gone from disk. Pinned alongside the above so a fix that narrows the
    /// eviction can't accidentally stop evicting.
    @Test("launch housekeeping still drops tiles that have expired")
    func expiryPassRemovesStaleTiles() async throws {
        let key = makeKey()
        try sandbox.browse(key: key)
        try sandbox.age(key: key, byDays: 8)

        let removed = await removeExpiredTiles()
        #expect(removed >= 1)
        #expect(!sandbox.isBrowsed(key))
        #expect(sandbox.cache.memoryImage(forKey: key) == nil)
    }

    // MARK: - What the memory tier is bounded by

    /// The unit the bound is expressed in. A tile arrives as a compressed PNG
    /// and is held as an uncompressed bitmap, so the file size says nothing
    /// about what the cache is holding — and a count of tiles says less.
    @Test("a tile is charged what its decoded bitmap costs, not what its file does")
    func tileCostIsTheDecodedSize() throws {
        let image = try #require(Fixture.fullSizeTileImage(scale: 2))
        let cost = TileCache.decodedByteCost(of: image)

        // 256 pt at @2x is 512×512 pixels, four bytes each. `bytesPerRow` may
        // be padded for alignment, so this is a floor rather than an equality.
        let pixels = 512 * 512
        #expect(cost >= pixels * 4)
        #expect(cost < pixels * 8, "and not wildly more than the pixels justify")
        #expect(
            cost > TileStore.tileData.count * 10,
            "the decoded cost dwarfs the file — which is why the file size was never the thing to bound"
        )
    }

    /// A cost of zero is free as far as `NSCache` is concerned, so an
    /// unmeasurable image must still be charged something or it would be exempt
    /// from the limit entirely.
    @Test("an image with no bitmap to measure still costs something")
    func unmeasurableImagesAreStillCharged() {
        #if canImport(UIKit)
        let blank = UIImage()
        #elseif canImport(AppKit)
        let blank = NSImage(size: .zero)
        #endif
        #expect(TileCache.decodedByteCost(of: blank) >= 1)
    }

    /// And that the cache is configured with it. The count limit is kept as a
    /// backstop, but at any real tile size the byte limit is the one that
    /// binds — which is the whole point of the change.
    @Test("the memory tier is bounded in bytes, and that's the bound that binds")
    func memoryTierIsBoundedInBytes() throws {
        let limits = sandbox.cache.memoryLimits
        #expect(limits.bytes == TileCache.memoryByteLimit)

        let tileCost = TileCache.decodedByteCost(of: try #require(Fixture.fullSizeTileImage(scale: 3)))
        #expect(
            limits.count * tileCost > limits.bytes,
            "the count limit alone would allow \(limits.count * tileCost / (1024 * 1024)) MB of tiles"
        )
    }

    /// And the guarantee the narrowed sweep now rests on entirely. With the
    /// disk pass no longer clearing the memory tier, this lazy check is the
    /// only thing standing between an expired tile and the screen — so it has
    /// to reject one that's already cached, and evict it while it's there.
    ///
    /// Driven by a reference date rather than by aging a file: a memory entry's
    /// age is when it was cached, which no amount of backdating on disk moves.
    @Test("an expired tile is never served from memory")
    func memoryLookupRejectsExpiredTiles() async throws {
        let key = makeKey()
        try sandbox.browse(key: key)

        let loaded = await sandbox.cache.loadTile(forKey: key, url: URL(string: "http://127.0.0.1:9/x.png")!)
        try #require(loaded != nil, "precondition: the tile is cached in memory")

        let pastTTL = Date(timeIntervalSinceNow: TileCache.tileExpirationInterval + 60)
        #expect(sandbox.cache.memoryImage(forKey: key, referenceDate: pastTTL) == nil)
        #expect(
            sandbox.cache.memoryImage(forKey: key) == nil,
            "and the lookup evicts it, rather than only declining to return it"
        )
    }
}
