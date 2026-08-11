//
//  TileCacheTierTests.swift
//  OpenTrailsTests
//
//  `TileCache` keeps the same tile under the same file name in two
//  directories — `Caches/OSMTiles` (browsing, OS-reclaimable) and
//  `Application Support/OSMTilesSaved` (offline coverage). The rest of the
//  suite treats those tiers as mutually exclusive, and the cache's job is to
//  make that true: **one key, at most one file.**
//
//  It isn't automatic. The two writers race — the map's renderer fetches
//  through `loadTile` and the bulk downloader through `saveTileDurably`, with
//  no shared in-flight set — so downloading the area you're looking at fetches
//  each tile twice and files the copies in different directories. These tests
//  pin the invariant from both ends: that no write path leaves two files, and
//  that no read path counts one key twice. Plus the one memory-tier behaviour
//  the launch path depends on.
//

import Foundation
import Testing
@testable import OpenTrails

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Nested inside `AutoSaveTests` to inherit its `.serialized` trait, for the
/// same reason `StorageAccountingTests` is: these write into — and, through
/// `removeExpiredTiles()`, delete across — the process's one real tile
/// directory pair, so they cannot run alongside anything else that does.
extension AutoSaveTests {

@Suite("Tile cache tiers")
struct TileCacheTierTests {
    private static func key(_ suffix: String = UUID().uuidString) -> String {
        "tiertest-\(suffix)/12/2200/1400@2.0"
    }

    /// Puts the same bytes in both tiers, which is what a `loadTile` write and
    /// a concurrent `promoteCachedTile` leave behind: the move creates the
    /// durable copy, and the fetch that was already in flight writes the
    /// ephemeral one back a moment later.
    private static func writeBothTiers(_ key: String) throws {
        try TileStore.browse(key: key)
        let saved = TileStore.savedFile(for: key)
        try FileManager.default.createDirectory(
            at: saved.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try TileStore.tileData.write(to: saved, options: .atomic)
    }

    private static func removeBothTiers(_ key: String) {
        try? FileManager.default.removeItem(at: TileStore.browsedFile(for: key))
        try? FileManager.default.removeItem(at: TileStore.savedFile(for: key))
    }

    /// How a tile ends up in both tiers at once: the map's renderer and the
    /// bulk downloader fetch through different entry points (`loadTile` and
    /// `saveTileDurably`) with no shared in-flight set between them, so
    /// downloading the area you are currently looking at fetches each tile
    /// twice and files the two copies in different directories.
    ///
    /// `promoteCachedTile` is where the two are reconciled: it already notices
    /// the durable copy and returns `true`, and now drops the redundant
    /// ephemeral one instead of leaving the tile occupying two files for the
    /// rest of its seven-day life. That was pure waste on the one axis this app
    /// is careful about everywhere else, and it inflated the residue figure
    /// that `trimCache` then worked to bring back down.
    @Test("promoting a tile that's already saved reclaims the redundant copy")
    func promotionReclaimsTheEphemeralDuplicate() async throws {
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try Self.writeBothTiers(key)

        let promoted = await offMain { TileCache.shared.promoteCachedTile(forKey: key) }
        #expect(promoted, "precondition: the tile counts as durably saved")
        #expect(TileStore.isSaved(key))
        #expect(!TileStore.isBrowsed(key), "one tile should not sit in two directories")
    }

    /// What that duplication did to the number the user reads. The hike sheet
    /// measures its offline coverage with `bytes(forKeys:)`, which stated both
    /// tiers per key and added them — so a duplicated tile was reported as
    /// twice the coverage it actually provides, and "Offline tiles · 24 MB"
    /// described 12 MB of map.
    @Test("a duplicated tile isn't reported as twice the coverage")
    func bytesDoesNotDoubleCountAcrossTiers() async throws {
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try Self.writeBothTiers(key)

        let measured = await offMain { TileCache.shared.bytes(forKeys: [key]) }
        #expect(measured == TileStore.tileByteCount)
    }

    /// The same double-count, on the screen that reports it app-wide. Settings
    /// enumerates both directories, so a duplicate showed up as two files there
    /// too — inflating whichever of "Saved for offline" or "Map cache" the key
    /// fell into.
    @Test("a duplicated tile is measured once by Settings")
    func diskUsageDoesNotDoubleCountAcrossTiers() async throws {
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try Self.writeBothTiers(key)

        let claimed = await offMain { TileCache.shared.diskUsage(claimedBy: [key]) }
        #expect(claimed.claimed == TileStore.tileByteCount, "counted once as coverage")

        let unclaimed = await offMain { TileCache.shared.diskUsage(claimedBy: []) }
        #expect(
            unclaimed.unclaimed >= TileStore.tileByteCount,
            "and once as cache when nothing claims it"
        )
        #expect(
            unclaimed.unclaimed - (await offMain { TileCache.shared.diskUsage(claimedBy: [key]) }).unclaimed
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
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try TileStore.browse(key: key)

        // An unreachable URL: a tile already on disk needs no fetch.
        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        #expect(await TileCache.shared.saveTileDurably(forKey: key, url: url))

        #expect(TileStore.isSaved(key))
        #expect(!TileStore.isBrowsed(key), "the browsing-tier copy is gone, not duplicated")
        #expect(await offMain { TileCache.shared.bytes(forKeys: [key]) } == TileStore.tileByteCount)
    }

    /// An expired tile is deleted where it lies and refetched. If the refetch
    /// always wrote to the browsing tier, a tile a hike is keeping offline
    /// would come back as OS-reclaimable cache — still claimed by the manifest,
    /// but no longer actually durable — and, before the delete-then-write was
    /// ordered properly, would sit alongside the expired durable file as a
    /// second copy of the same key.
    @Test("refetching an expired tile keeps it in the tier it was in")
    func refetchPreservesTheDurableTier() async throws {
        let key = Self.key()
        defer { Self.removeBothTiers(key) }

        // Durably saved, then aged past the seven-day TTL.
        try Self.writeBothTiers(key)
        try? FileManager.default.removeItem(at: TileStore.browsedFile(for: key))
        try TileStore.age(key: key, byDays: 8)

        let url = try #require(URL(string: "https://tile.invalid/never-fetched.png"))
        _ = await TileCache.shared.loadTile(forKey: key, url: url)

        // The fetch fails (unreachable), so what's pinned here is that the
        // expired durable copy was dropped and nothing was written to the
        // browsing tier in its place.
        #expect(!TileStore.isBrowsed(key), "an expired durable tile must not reappear as cache")
    }

    /// Installs that already have duplicates from earlier builds heal at the
    /// next launch rather than carrying them for another seven days.
    @Test("launch housekeeping reclaims duplicates left by earlier builds")
    func expiryPassReclaimsDuplicates() async throws {
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try Self.writeBothTiers(key)

        let removed = await offMain { TileCache.shared.removeExpiredTiles() }
        #expect(removed >= 1)
        #expect(TileStore.isSaved(key), "the durable copy is the one that's kept")
        #expect(!TileStore.isBrowsed(key))
    }

    /// `OpenTrailsApp.init` kicks off `removeExpiredTiles()` on a detached task
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
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try TileStore.browse(key: key)

        // A disk read is what populates the memory tier — no network involved.
        let loaded = await TileCache.shared.loadTile(forKey: key, url: URL(string: "http://127.0.0.1:9/x.png")!)
        try #require(loaded != nil, "precondition: the tile is cached in memory")
        try #require(TileCache.shared.memoryImage(forKey: key) != nil)

        let removed = await offMain { TileCache.shared.removeExpiredTiles() }
        #expect(removed == 0, "the tile is fresh, so nothing should have been deleted from disk")
        #expect(TileStore.isBrowsed(key), "and it's still on disk")
        #expect(
            TileCache.shared.memoryImage(forKey: key) != nil,
            "a fresh tile shouldn't have to be read back off disk because an unrelated one expired"
        )
    }

    /// The other launch-time sweep, with the same reasoning: `trimCache` runs
    /// from `ContentView` on every launch, and a tile it leaves on disk must
    /// still be in memory afterwards. (An over-the-limit trim is what makes
    /// this reachable at all — under the limit it returns before touching
    /// anything.)
    @Test("a cache trim doesn't evict tiles it decided to keep")
    func trimKeepsFreshMemoryTiles() async throws {
        let kept = Self.key()
        defer { Self.removeBothTiers(kept) }
        try TileStore.browse(key: kept)

        let loaded = await TileCache.shared.loadTile(forKey: kept, url: URL(string: "http://127.0.0.1:9/x.png")!)
        try #require(loaded != nil, "precondition: the tile is cached in memory")

        // Claimed, so the trim can't delete it however far over the limit we are.
        let freed = await offMain {
            TileCache.shared.trimCache(claimedBy: [kept], limit: TileStore.tileByteCount)
        }
        #expect(freed >= 0)
        #expect(TileStore.isBrowsed(kept), "precondition: a claimed tile survives the trim")
        #expect(
            TileCache.shared.memoryImage(forKey: kept) != nil,
            "a tile the trim kept on disk shouldn't be dropped from memory by it"
        )
    }

    /// The half of the same pass that must keep working: an expired tile is
    /// gone from disk. Pinned alongside the above so a fix that narrows the
    /// eviction can't accidentally stop evicting.
    @Test("launch housekeeping still drops tiles that have expired")
    func expiryPassRemovesStaleTiles() async throws {
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try TileStore.browse(key: key)
        try TileStore.age(key: key, byDays: 8)

        let removed = await offMain { TileCache.shared.removeExpiredTiles() }
        #expect(removed >= 1)
        #expect(!TileStore.isBrowsed(key))
        #expect(TileCache.shared.memoryImage(forKey: key) == nil)
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
    func unmeasurableImagesAreStillCharged() throws {
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
        let stub = StubbedTileCache()
        defer { stub.tearDown() }

        let limits = stub.cache.memoryLimits
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
        let key = Self.key()
        defer { Self.removeBothTiers(key) }
        try TileStore.browse(key: key)

        let loaded = await TileCache.shared.loadTile(forKey: key, url: URL(string: "http://127.0.0.1:9/x.png")!)
        try #require(loaded != nil, "precondition: the tile is cached in memory")

        let pastTTL = Date(timeIntervalSinceNow: TileCache.tileExpirationInterval + 60)
        #expect(TileCache.shared.memoryImage(forKey: key, referenceDate: pastTTL) == nil)
        #expect(
            TileCache.shared.memoryImage(forKey: key) == nil,
            "and the lookup evicts it, rather than only declining to return it"
        )
    }
}

}
