//
//  TileCache.swift
//  OpenTrails
//
//  Two-tier (memory + disk) tile cache with async network loading.
//

import Foundation
import MapKit
import Network
import os

#if canImport(UIKit)
import UIKit
typealias TileImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias TileImage = NSImage
#endif

/// Receives connectivity callbacks from ``TileCache``, always on the main queue.
/// Renderers adopt this to retry tiles once the network is back.
protocol TileCacheObserver: AnyObject {
    func tileCacheDidReconnect()
}

/// Caches map tiles in memory (`NSCache`) and on disk, fetching missing tiles
/// over the network. Safe to call from any thread/task.
nonisolated final class TileCache: @unchecked Sendable {
    static let shared = TileCache()

    private static let logger = Logger(subsystem: "OpenTrails", category: "TileRequests")

    private let memory = NSCache<NSString, TileImage>()
    private let directory: URL
    /// Durable (non-purgeable) store for tiles the user has explicitly chosen to
    /// keep, e.g. via ``AutoSaveTileStore``. Unlike `directory`, this lives under
    /// Application Support, so it survives OS storage-pressure cache eviction.
    private let durableDirectory: URL
    private let session: URLSession

    /// Live network reachability, updated by `NWPathMonitor`. Tile loads short-
    /// circuit when this is `false`, so an offline app doesn't fire (and log) a
    /// doomed request for every visible tile.
    private let online = OSAllocatedUnfairLock(initialState: true)
    var isOnline: Bool { online.withLock { $0 } }

    /// Weakly-held reconnect listeners. A boxed array keeps the reference weak so
    /// a deallocated renderer drops out without needing to unregister.
    private struct WeakObserver { weak var value: TileCacheObserver? }
    private let observers = OSAllocatedUnfairLock(initialState: [WeakObserver]())

    private let monitor = NWPathMonitor()

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("OSMTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        durableDirectory = support.appendingPathComponent("OSMTilesSaved", isDirectory: true)
        try? FileManager.default.createDirectory(at: durableDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        // OSM's tile usage policy requires an identifying User-Agent.
        config.httpAdditionalHeaders = ["User-Agent": "OpenTrails/1.0 (iOS; hiking app)"]
        // Don't sit in a retry queue when offline — fail fast so the caller can
        // record the miss and stop asking until we're back online.
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)

        memory.countLimit = 1_024

        startMonitoringNetwork()
    }

    /// Tracks reachability and, on each offline→online transition, notifies
    /// renderers so they clear failed tiles and try again.
    private func startMonitoringNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let wasOnline = self.online.withLock { previous in
                let old = previous
                previous = satisfied
                return old
            }
            if satisfied && !wasOnline { self.notifyReconnect() }
        }
        monitor.start(queue: DispatchQueue(label: "TileCache.network"))
    }

    /// Registers a reconnect listener; held weakly, so no explicit removal is
    /// required (though ``removeObserver(_:)`` is available).
    func addObserver(_ observer: TileCacheObserver) {
        observers.withLock { boxes in
            boxes.removeAll { $0.value == nil }
            boxes.append(WeakObserver(value: observer))
        }
    }

    func removeObserver(_ observer: TileCacheObserver) {
        observers.withLock { boxes in
            boxes.removeAll { $0.value == nil || $0.value === observer }
        }
    }

    private func notifyReconnect() {
        // MKOverlayRenderer.setNeedsDisplay must run on the main thread; the path
        // handler fires on a background queue, so hop first, then read observers
        // there (keeps the non-Sendable listeners off the queue boundary).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let live = self.observers.withLock { boxes -> [TileCacheObserver] in
                boxes.removeAll { $0.value == nil }
                return boxes.compactMap(\.value)
            }
            live.forEach { $0.tileCacheDidReconnect() }
        }
    }

    /// Fast, synchronous memory-only lookup — safe to call from the render loop.
    func memoryImage(forKey key: String) -> TileImage? {
        memory.object(forKey: key as NSString)
    }

    /// Loads a tile for display, checking memory, then disk (ephemeral, then
    /// durable), then the network, and populating the faster tiers as it goes.
    ///
    /// The browsing path: a tile fetched to draw the map is cached where the OS
    /// may reclaim it, which is the right trade for something nobody asked to
    /// keep. Tiles that *are* meant to survive go through
    /// ``saveTileDurably(forKey:url:)`` or ``promoteCachedTile(forKey:)``.
    @discardableResult
    func loadTile(forKey key: String, url: URL) async -> TileImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let image = diskImage(forKey: key) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        // Offline: the tile isn't cached and the network is gone. Return without
        // requesting so we don't spam failing loads for every visible tile.
        guard isOnline else {
            #if DEBUG
            Self.logger.debug("Skipped tile \(key, privacy: .public): offline")
            #endif
            return nil
        }

        guard let fetched = await fetchTile(forKey: key, url: url) else { return nil }
        try? fetched.data.write(to: directory.appendingPathComponent(diskName(for: key)), options: .atomic)
        memory.setObject(fetched.image, forKey: key as NSString)
        return fetched.image
    }

    /// Fetches a tile straight into durable storage — the bulk-download path.
    ///
    /// The counterpart to ``loadTile(forKey:url:)``: same network fetch, but the
    /// bytes land where the OS can't reclaim them. A download is coverage the
    /// user explicitly asked for, and `Caches` is the first thing purged under
    /// storage pressure — a tile evicted from under a saved hike is offline
    /// coverage that silently isn't there when they're out of signal.
    ///
    /// Returns whether the tile is durably saved once this returns.
    @discardableResult
    func saveTileDurably(forKey key: String, url: URL) async -> Bool {
        // Already saved by an earlier download or by auto-save, or already
        // browsed and so sitting on disk in the wrong tier: either way, no
        // reason to ask the tile server for a second copy.
        if promoteCachedTile(forKey: key) { return true }

        guard isOnline, let fetched = await fetchTile(forKey: key, url: url) else { return false }
        memory.setObject(fetched.image, forKey: key as NSString)
        return writeDurable(fetched.data, forKey: key)
    }

    /// The tile as it sits on disk, ephemeral tier first — it's the one a
    /// browsing fetch refreshes, and the two hold the same image.
    private func diskImage(forKey key: String) -> TileImage? {
        let name = diskName(for: key)
        for directory in [directory, durableDirectory] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let image = TileImage(data: data) {
                return image
            }
        }
        return nil
    }

    /// One tile off the network, validated and decoded, with nothing written
    /// anywhere — the caller decides which tier it belongs in.
    private func fetchTile(forKey key: String, url: URL) async -> (data: Data, image: TileImage)? {
        #if DEBUG
        Self.logger.debug("Requesting tile \(key, privacy: .public) from \(url.absoluteString, privacy: .public)")
        #endif

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                #if DEBUG
                Self.logger.error("Tile \(key, privacy: .public): response was not HTTP")
                #endif
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                #if DEBUG
                Self.logger.error("Tile \(key, privacy: .public) failed: HTTP \(http.statusCode, privacy: .public) (\(data.count, privacy: .public) bytes) from \(url.absoluteString, privacy: .public)")
                #endif
                return nil
            }
            guard let image = TileImage(data: data) else {
                #if DEBUG
                Self.logger.error("Tile \(key, privacy: .public) failed: undecodable response (\(data.count, privacy: .public) bytes, HTTP \(http.statusCode, privacy: .public), content-type \(http.value(forHTTPHeaderField: "Content-Type") ?? "unknown", privacy: .public))")
                #endif
                return nil
            }

            #if DEBUG
            Self.logger.debug("Fetched tile \(key, privacy: .public) (\(data.count, privacy: .public) bytes)")
            #endif
            return (data, image)
        } catch {
            #if DEBUG
            Self.logger.error("Tile \(key, privacy: .public) request failed: \(error.localizedDescription, privacy: .public)")
            #endif
            return nil
        }
    }

    /// Moves the browsing cache's copy of a tile into durable storage, keeping
    /// the bytes exactly as the tile server sent them. Used by
    /// ``AutoSaveTileStore`` for tiles the user has already viewed, and so
    /// already fetched through ``loadTile(forKey:url:)``, which is what put that
    /// cached copy there.
    ///
    /// A move, not a re-encode. Providers serve PNG, which is what flat-filled,
    /// sharp-edged cartography compresses best in, so those bytes are already
    /// both the smallest and the only lossless representation on offer: a
    /// lossless PNG round-trip through ImageIO measured +10% on real tiles, and
    /// HEIC at full quality +178%. Lossy HEIC did save 7% on average, but
    /// inflated flat tiles (desert, coastline, low-zoom overviews) by up to 4×,
    /// which is exactly backwards. Moving the file instead also keeps a decode
    /// and an encode off the drawing path entirely.
    ///
    /// Returns whether the tile is durably stored once this returns — including
    /// when it already was, which is what lets a second hike over the same
    /// ground claim tiles the first one saved.
    @discardableResult
    func promoteCachedTile(forKey key: String) -> Bool {
        let name = diskName(for: key)
        let durable = durableDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: durable.path) { return true }
        do {
            try FileManager.default.moveItem(at: directory.appendingPathComponent(name), to: durable)
            return true
        } catch {
            // Nothing cached to promote — the tile was served from memory after
            // its disk copy went (an OS purge of `Caches`, say). Callers drop
            // their claim, so this is retried next time the tile is drawn.
            #if DEBUG
            Self.logger.debug("No cached tile to save for \(key, privacy: .public)")
            #endif
            return false
        }
    }

    /// Writes freshly-fetched bytes straight to durable storage, for the
    /// download path — where there's no cached copy to move.
    private func writeDurable(_ data: Data, forKey key: String) -> Bool {
        do {
            try data.write(to: durableDirectory.appendingPathComponent(diskName(for: key)), options: .atomic)
            return true
        } catch {
            #if DEBUG
            Self.logger.error("Failed to save tile \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
            return false
        }
    }

    private func diskName(for key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "@", with: "_")
    }

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
        assertOffMainThread("diskUsage(claimedBy:) enumerates and stats every cached tile file — call it off the main thread")
        let claimedNames = Set(keys.map(diskName(for:)))
        var usage = DiskUsage()
        for file in allTileFiles(in: directory) + allTileFiles(in: durableDirectory) {
            if claimedNames.contains(file.lastPathComponent) {
                usage.claimed += fileSize(file)
            } else {
                usage.unclaimed += fileSize(file)
            }
        }
        return usage
    }

    /// Bytes used by the tiles for `keys` that are actually present on disk
    /// (ephemeral or durable).
    func bytes(forKeys keys: [String]) -> Int64 {
        assertOffMainThread("bytes(forKeys:) stats two files per key — call it off the main thread")
        return keys.reduce(0) { total, key in
            let name = diskName(for: key)
            return total
                + fileSize(directory.appendingPathComponent(name))
                + fileSize(durableDirectory.appendingPathComponent(name))
        }
    }

    /// Removes every cached tile (memory + ephemeral disk + durable disk).
    func removeAllTiles() {
        assertOffMainThread("removeAllTiles() deletes every cached tile file synchronously — call it off the main thread")
        memory.removeAllObjects()
        for file in allTileFiles(in: directory) + allTileFiles(in: durableDirectory) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes every tile `keys` doesn't claim, leaving offline coverage intact.
    ///
    /// The memory cache is dropped wholesale rather than picked through: its
    /// entries are keyed by tile, not by file, and everything worth keeping is
    /// still on disk to be read back.
    func removeTiles(unclaimedBy keys: Set<String>) {
        assertOffMainThread("removeTiles(unclaimedBy:) enumerates and deletes tile files synchronously — call it off the main thread")
        let claimedNames = Set(keys.map(diskName(for:)))
        memory.removeAllObjects()
        for file in allTileFiles(in: directory) + allTileFiles(in: durableDirectory)
        where !claimedNames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
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
    @discardableResult
    func trimCache(claimedBy keys: Set<String>, limit: Int64 = TileCache.cacheByteLimit) -> Int64 {
        assertOffMainThread("trimCache(claimedBy:) stats and deletes tile files synchronously — call it off the main thread")
        let claimedNames = Set(keys.map(diskName(for:)))

        var unclaimed: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for file in allTileFiles(in: directory) + allTileFiles(in: durableDirectory)
        where !claimedNames.contains(file.lastPathComponent) {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            unclaimed.append((file, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > limit else { return 0 }

        // The memory cache is keyed by tile, not by file, so there's no way to
        // evict just the entries being deleted — and no need to, since anything
        // still wanted is a disk read away.
        memory.removeAllObjects()

        let target = Int64(Double(limit) * Self.trimTargetFraction)
        var freed: Int64 = 0
        for tile in unclaimed.sorted(by: { $0.modified < $1.modified }) {
            guard total - freed > target else { break }
            guard (try? FileManager.default.removeItem(at: tile.url)) != nil else { continue }
            freed += tile.size
        }
        #if DEBUG
        Self.logger.debug("Trimmed \(freed, privacy: .public) bytes of unclaimed tiles (was \(total, privacy: .public))")
        #endif
        return freed
    }

    /// Removes the tiles for `keys` (memory + ephemeral disk + durable disk).
    /// Missing files are ignored.
    func removeTiles(forKeys keys: [String]) {
        assertOffMainThread("removeTiles(forKeys:) deletes two files per key synchronously — call it off the main thread")
        for key in keys {
            memory.removeObject(forKey: key as NSString)
            let name = diskName(for: key)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: durableDirectory.appendingPathComponent(name))
        }
    }

    private func allTileFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
