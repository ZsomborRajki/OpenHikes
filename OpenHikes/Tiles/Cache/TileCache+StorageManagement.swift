//
//  TileCache+StorageManagement.swift
//  OpenHikes
//

import Foundation
import os
import Synchronization

nonisolated extension TileCache {

    // MARK: - Storage management

    /// How the tiles on disk divide between offline coverage and browsing.
    struct DiskUsage: Equatable, Sendable {
        /// Bytes held by tiles some hike's manifest claims — what the hike
        /// sheets add up to, and what has to survive a cache clear.
        var claimed: Int64 = 0
        /// Bytes held by everything else: tiles fetched to draw the map that no
        /// hike ever claimed (panned past the corridor, browsed before anything
        /// was selected, over a hike's cap), which nothing reclaims on its own.
        var unclaimed: Int64 = 0

        var total: Int64 { claimed + unclaimed }
    }

    /// Splits every tile on disk into the ones `keys` claims and the rest.
    ///
    /// Deliberately *not* split by storage tier: which directory a tile landed
    /// in says how it was fetched, not whether anything still wants it. A bulk
    /// download populates the ephemeral cache and is very much offline
    /// coverage; a tile browsed past the corridor lands there too and is
    /// nothing but residue. The manifests are the only thing that knows the
    /// difference, so they're what this buckets by.
    func diskUsage(claimedBy keys: Set<String>) -> DiskUsage {
        assertOffMainThread(
            "diskUsage(claimedBy:) enumerates and stats every cached tile file — call it off the main thread"
        )
        let claimedNames = Set(keys.map(diskName(for:)))
        var usage = DiskUsage()
        // Durable first, then skip any name already seen: one tile is one tile
        // however many tiers it managed to land in, and this number is what the
        // user reads as "how much space is this app using".
        var counted = Set<String>()
        for file in allTileFiles(in: durableDirectory) + allTileFiles(in: directory) {
            guard counted.insert(file.lastPathComponent).inserted else { continue }
            if claimedNames.contains(file.lastPathComponent) {
                usage.claimed += fileSize(file)
            } else {
                usage.unclaimed += fileSize(file)
            }
        }
        return usage
    }

    /// Bytes used by the tiles for `keys` that are actually present on disk.
    ///
    /// One tier per key — the durable copy if there is one, otherwise the
    /// browsing one. Summing both tiers billed a hike twice for any tile that
    /// had a copy in each.
    ///
    /// Cancellable: a hike with a full offline download stats thousands of
    /// files, and leaving the screen mid-scan should stop the scan rather than
    /// discard its result. Outside a task `Task.isCancelled` is always `false`,
    /// so a synchronous caller simply never sees the throw.
    func bytes(forKeys keys: [String]) throws(CancellationError) -> Int64 {
        assertOffMainThread(
            "bytes(forKeys:) stats up to two files per key — call it off the main thread"
        )
        var total: Int64 = 0
        for (index, key) in keys.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled {
                throw CancellationError()
            }
            let (cached, durable) = filePaths(forKey: key)
            let durableSize = fileSize(durable)
            total += durableSize > 0 ? durableSize : fileSize(cached)
        }
        return total
    }

    /// Removes every cached tile (memory + ephemeral disk + durable disk).
    func removeAllTiles() {
        assertOffMainThread(
            "removeAllTiles() deletes every cached tile file synchronously — call it off the main thread"
        )
        mutationVersions.withLock { versions in
            versions.invalidateAll()
            memory.removeAllObjects()
            for file in allTileFiles(in: directory)
                + allTileFiles(in: durableDirectory) {
                _ = removeItemIgnoringNotFound(
                    at: file,
                    operation: "remove all tiles"
                )
            }
        }
    }

    /// Removes every tile `keys` doesn't claim, leaving offline coverage intact.
    ///
    /// The memory cache is dropped wholesale rather than picked through: its
    /// entries are keyed by tile, not by file, and everything worth keeping is
    /// still on disk to be read back.
    func removeTiles(unclaimedBy keys: Set<String>) {
        assertOffMainThread(
            "removeTiles(unclaimedBy:) enumerates and deletes tile files synchronously — call it off the main thread"
        )
        let claimedNames = Set(keys.map(diskName(for:)))
        mutationVersions.withLock { versions in
            versions.invalidateAll()
            memory.removeAllObjects()
            for file in allTileFiles(in: directory)
                + allTileFiles(in: durableDirectory)
            where !claimedNames.contains(file.lastPathComponent) {
                _ = removeItemIgnoringNotFound(
                    at: file,
                    operation: "remove unclaimed tile"
                )
            }
        }
    }

    /// Ceiling on tiles no hike claims. At roughly 30 KB a tile that's ~17,000
    /// of them — plenty to pan around on without refetching, and small enough
    /// that browsing can never be the reason a phone runs out of room.
    ///
    /// Deliberately a cap on the *cache* and not on offline coverage. A hike's
    /// saved map is data the user asked for, to have on a trail with no signal;
    /// deleting it to stay under a number is the one failure this app can't
    /// afford. Residue is the half that grows without anyone asking, so it's
    /// the half that's bounded.
    static let cacheByteLimit: Int64 = 500 * 1024 * 1024

    /// How far under the limit a trim goes. Trimming to exactly the limit would
    /// mean doing it again on the next launch after a few tiles, for a few
    /// tiles; leaving headroom makes it an occasional job instead.
    private static let trimTargetFraction = 0.8

    /// Brings unclaimed tiles back under `limit`, oldest first, and leaves
    /// everything `keys` claims alone. No-op below the limit.
    ///
    /// Oldest by modification date, which for a tile is when it was fetched or
    /// last re-fetched — so what goes is the ground the user has been away from
    /// longest. Returns the bytes freed.
    ///
    /// `limit` is a parameter only so tests can drive it with a handful of
    /// tiles instead of half a gigabyte; callers pass the default.
    @discardableResult func trimCache(
        claimedBy keys: Set<String>,
        limit: Int64 = TileCache.cacheByteLimit
    ) -> Int64 {
        assertOffMainThread(
            "trimCache(claimedBy:) stats and deletes tile files synchronously — call it off the main thread"
        )
        let claimedNames = Set(keys.map(diskName(for:)))

        var unclaimed: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for file in allTileFiles(in: directory) + allTileFiles(in: durableDirectory)
        where !claimedNames.contains(file.lastPathComponent) {
            let values: URLResourceValues?
            do {
                values = try file.resourceValues(
                    forKeys: [
                        .fileSizeKey,
                        .contentModificationDateKey,
                    ]
                )
            } catch {
                logFileError(
                    error,
                    operation: "read tile metadata",
                    url: file
                )
                values = nil
            }
            let size = Int64(values?.fileSize ?? 0)
            unclaimed.append((file, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > limit else {
            return 0
        }

        // Disk only, for the same reason as `removeExpiredTiles()`: this also
        // runs at launch, and dropping the memory tier would throw away the
        // tiles currently on screen to reclaim space on disk they aren't using.
        // A trimmed tile still in memory draws until it's evicted normally,
        // which is strictly better than refetching it from the provider.
        let target = Int64(Double(limit) * Self.trimTargetFraction)
        var freed: Int64 = 0
        for tile in unclaimed.sorted(by: { $0.modified < $1.modified }) {
            guard total - freed > target else { break }
            guard removeItemIgnoringNotFound(
                at: tile.url,
                operation: "trim cached tile"
            ) else {
                continue
            }
            freed += tile.size
        }
        #if DEBUG
        let freedStr = "Trimmed \(freed) bytes unclaimed (was \(total))"
        Self.logger.debug("\(freedStr, privacy: .public)")
        #endif
        return freed
    }

    /// Removes the tiles for `keys` (memory + ephemeral disk + durable disk).
    /// Missing files are ignored.
    func removeTiles(forKeys keys: [String]) {
        assertOffMainThread(
            "removeTiles(forKeys:) deletes two files per key synchronously — call it off the main thread"
        )
        for key in keys {
            mutationVersions.withLock { versions in
                versions.invalidate(key)
                // swiftlint:disable:next legacy_objc_type
                memory.removeObject(forKey: key as NSString)
                let paths = filePaths(forKey: key)
                _ = removeItemIgnoringNotFound(
                    at: paths.cached,
                    operation: "remove cached tile"
                )
                _ = removeItemIgnoringNotFound(
                    at: paths.durable,
                    operation: "remove durable tile"
                )
            }
        }
    }
}
