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

    private final class MemoryTile: @unchecked Sendable {
        let image: TileImage
        let storedAt: Date
        /// What this entry costs the memory tier — see
        /// ``TileCache/decodedByteCost(of:)``. Computed once, at insertion.
        let byteCost: Int

        init(image: TileImage, storedAt: Date) {
            self.image = image
            self.storedAt = storedAt
            self.byteCost = TileCache.decodedByteCost(of: image)
        }
    }

    /// Bytes the decoded bitmap for `image` occupies.
    ///
    /// The number that matters, and not the one the cache used to be bounded
    /// by. A tile arrives as a compressed PNG of a few tens of kilobytes and is
    /// held as an uncompressed bitmap — 256×256 at `@3x` is 768×768×4 bytes,
    /// about 2.25 MB, roughly seventy times its file size. Counting *tiles*
    /// therefore said almost nothing about the memory being used.
    static func decodedByteCost(of image: TileImage) -> Int {
        #if canImport(UIKit)
        let bitmap = image.cgImage
        #elseif canImport(AppKit)
        let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        if let bitmap, bitmap.bytesPerRow > 0, bitmap.height > 0 {
            return bitmap.bytesPerRow * bitmap.height
        }
        // No backing bitmap to measure. Estimate from the point size at four
        // bytes a pixel rather than charging nothing, which would exempt the
        // entry from the limit entirely — `NSCache` treats a zero cost as free.
        return max(Int(image.size.width * image.size.height * 4), 1)
    }

    /// One tile off the network: the bytes exactly as served, plus the decoded
    /// image. `@unchecked Sendable` for the same reason ``MemoryTile`` is —
    /// `NSImage` isn't `Sendable`, and a decoded tile is never mutated after
    /// this is built.
    private struct FetchedTile: @unchecked Sendable {
        let data: Data
        let image: TileImage
    }

    /// OSM requires cached tiles to honor response caching headers, or to use
    /// at least a seven-day TTL when the client does not persist those headers.
    static let tileExpirationInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Ceiling on the decoded bytes held in the memory tier.
    ///
    /// About 57 tiles at `@3x` or 128 at `@2x` — five or so screenfuls, which
    /// is the working set panning and zooming actually reuse, plus the
    /// lower-zoom ancestors the overzoom fallback draws while they load.
    ///
    /// The tier was previously bounded only by `countLimit = 1_024`, which at
    /// `@3x` is an effective ceiling near 2 GB. `NSCache` does evict under
    /// memory pressure, so that was pressure-driven rather than a hard leak —
    /// but a limit expressed in tiles says nothing about the resource being
    /// spent, and left the app relying on the system noticing.
    static let memoryByteLimit = 128 * 1024 * 1024

    private let memory = NSCache<NSString, MemoryTile>()
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

    /// Network fetches currently in flight, keyed by cache key.
    ///
    /// The map and the bulk downloader reach the network through different
    /// entry points — ``loadTile(forKey:url:)`` and
    /// ``saveTileDurably(forKey:url:)`` — so downloading the area you're
    /// looking at had both asking the provider for every tile independently.
    /// That doubles the request load on servers whose usage policies are the
    /// reason this app has an auto-save mechanism at all.
    ///
    /// Keyed by cache key rather than URL: the key is what both callers already
    /// agree identifies a tile, and it's what the tiers file it under.
    private let inFlightFetches = OSAllocatedUnfairLock(initialState: [String: Task<FetchedTile?, Never>]())

    /// Weakly-held reconnect listeners. A boxed array keeps the reference weak so
    /// a deallocated renderer drops out without needing to unregister.
    private struct WeakObserver { weak var value: TileCacheObserver? }
    private let observers = OSAllocatedUnfairLock(initialState: [WeakObserver]())

    private let monitor = NWPathMonitor()
    private let monitorsNetwork: Bool

    /// OSM's tile usage policy requires an identifying User-Agent. Named so a
    /// test can assert on the header the app really sends rather than on a
    /// copy of the string.
    static let userAgent = "OpenTrails/1.0 (iOS; hiking app)"

    /// The subdirectory names for the two tiers, under whichever roots they
    /// end up in — so a test cache lays its files out exactly as the app's does.
    private static let cacheDirectoryName = "OSMTiles"
    private static let durableDirectoryName = "OSMTilesSaved"

    /// - Parameters:
    ///   - storageRoot: parent of both tiers. `nil` — the app — puts the
    ///     browsing tier under `Caches`, where the OS may reclaim it, and the
    ///     durable tier under `Application Support`, where it may not. A test
    ///     passes one temporary directory so it isn't sharing the real pair
    ///     with every other suite in the process.
    ///   - sessionConfiguration: `nil` builds the standard one. A test passes
    ///     a configuration carrying a `URLProtocol` stub, so no request leaves
    ///     the process and every response is chosen by the test. The headers
    ///     and connectivity policy below are applied either way, so what the
    ///     stub sees is what a tile server would have.
    ///   - monitorsNetwork: `false` leaves reachability wherever
    ///     `setReachable(_:)` puts it, so a test isn't at the mercy of the
    ///     machine's own connection.
    init(
        storageRoot: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        monitorsNetwork: Bool = true
    ) {
        let cacheRoot = storageRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let durableRoot = storageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = cacheRoot.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        durableDirectory = durableRoot.appendingPathComponent(Self.durableDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: durableDirectory, withIntermediateDirectories: true)

        let config = sessionConfiguration ?? URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        // Don't sit in a retry queue when offline — fail fast so the caller can
        // record the miss and stop asking until we're back online.
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)

        memory.totalCostLimit = Self.memoryByteLimit
        // A secondary backstop, kept for the pathological case of very small
        // tiles. The byte limit is what binds at any real tile size.
        memory.countLimit = 1_024

        self.monitorsNetwork = monitorsNetwork
        if monitorsNetwork { startMonitoringNetwork() }
    }

    deinit {
        if monitorsNetwork { monitor.cancel() }
    }

    /// Tracks reachability and, on each offline→online transition, notifies
    /// renderers so they clear failed tiles and try again.
    private func startMonitoringNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.applyReachability(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "TileCache.network"))
    }

    /// Records reachability, notifying renderers only on an offline→online
    /// edge. Shared by the monitor and by ``setReachable(_:)`` so the two
    /// can't disagree about what a reconnect is.
    private func applyReachability(_ satisfied: Bool) {
        let wasOnline = online.withLock { previous in
            let old = previous
            previous = satisfied
            return old
        }
        if satisfied && !wasOnline { notifyReconnect() }
    }

    #if DEBUG
    /// Test hook: drives the reachability transitions a cache built with
    /// `monitorsNetwork: false` never receives — including the reconnect
    /// notification renderers listen for to retry failed tiles.
    func setReachable(_ reachable: Bool) {
        applyReachability(reachable)
    }

    /// Test hook: the bounds the memory tier was actually configured with,
    /// rather than the constants it was meant to be configured from.
    var memoryLimits: (count: Int, bytes: Int) {
        (memory.countLimit, memory.totalCostLimit)
    }
    #endif

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
    ///
    /// Applies the TTL lazily, evicting as it finds one expired. This is the
    /// *only* thing keeping a stale tile off the screen — the disk sweeps
    /// deliberately don't touch this tier — so an expired entry must never be
    /// returned from here, however it got in.
    ///
    /// `referenceDate` is defaulted for the same reason it is on
    /// ``removeExpiredTiles(referenceDate:)``: a test can't wait out a
    /// seven-day TTL, and a memory entry's age comes from when it was cached
    /// rather than from a file it could backdate.
    /// Puts a tile in the memory tier, charged at its decoded size.
    ///
    /// The single insertion point on purpose: `setObject(_:forKey:)` without a
    /// cost enters as free, and one call site that forgot would quietly exempt
    /// its tiles from ``memoryByteLimit`` — with no symptom until the app is
    /// killed for memory somewhere else entirely.
    private func cacheInMemory(_ image: TileImage, storedAt: Date, forKey key: String) {
        let tile = MemoryTile(image: image, storedAt: storedAt)
        memory.setObject(tile, forKey: key as NSString, cost: tile.byteCost)
    }

    func memoryImage(forKey key: String, referenceDate: Date = Date()) -> TileImage? {
        let cacheKey = key as NSString
        guard let tile = memory.object(forKey: cacheKey) else { return nil }
        guard !isExpired(tile.storedAt, referenceDate: referenceDate) else {
            memory.removeObject(forKey: cacheKey)
            return nil
        }
        return tile.image
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
        if let cached = memoryImage(forKey: key) { return cached }

        // Which tier holds this key, read *before* `diskImage` — it deletes an
        // expired file as it finds it, and the answer decides where a refetched
        // tile is written back below.
        let paths = filePaths(forKey: key)
        let wasDurable = FileManager.default.fileExists(atPath: paths.durable.path)

        if let tile = diskImage(forKey: key) {
            cacheInMemory(tile.image, storedAt: tile.storedAt, forKey: key)
            return tile.image
        }

        // Offline: the tile isn't cached and the network is gone. Return without
        // requesting so we don't spam failing loads for every visible tile.
        guard isOnline else {
            #if DEBUG
            Self.logger.debug("Skipped tile \(key, privacy: .public): offline")
            #endif
            return nil
        }

        guard let fetched = await fetchTileOnce(forKey: key, url: url) else { return nil }
        // Back into the tier it came from. A tile that was durable is offline
        // coverage some hike is counting on; writing its replacement to the
        // browsing tier instead would leave the manifest still claiming it while
        // the OS is free to reclaim it — and, before this wrote to one tier
        // rather than always to `directory`, left the expired durable copy
        // sitting alongside the new one as a second file for the same key.
        try? fetched.data.write(to: wasDurable ? paths.durable : paths.cached, options: .atomic)
        // A download sharing this very fetch may have filed the same bytes
        // durably in between the check above and the write just now. Coalescing
        // means both callers resume from one result — it doesn't order their
        // writes, so the reconciliation still has to happen here.
        discardRedundantCachedCopy(forKey: key)
        cacheInMemory(fetched.image, storedAt: Date(), forKey: key)
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

        guard isOnline, let fetched = await fetchTileOnce(forKey: key, url: url) else { return false }
        cacheInMemory(fetched.image, storedAt: Date(), forKey: key)
        return writeDurable(fetched.data, forKey: key)
    }

    /// The tile as it sits on disk, ephemeral tier first — it's the one a
    /// browsing fetch refreshes, and the two hold the same image.
    private func diskImage(forKey key: String) -> (image: TileImage, storedAt: Date)? {
        let name = diskName(for: key)
        for directory in [directory, durableDirectory] {
            let file = directory.appendingPathComponent(name)
            guard let storedAt = freshModificationDate(for: file) else { continue }
            if let data = try? Data(contentsOf: file),
               let image = TileImage(data: data) {
                return (image, storedAt)
            }
        }
        return nil
    }

    /// One tile off the network per key, however many callers ask at once.
    ///
    /// The first caller starts the fetch and the rest await its result, so the
    /// map drawing a tile while a download saves it costs the provider one
    /// request instead of two. Each caller still applies its own storage
    /// policy to the bytes that come back — coalescing the *fetch* is the point;
    /// where the tile is filed is the caller's business.
    ///
    /// The entry is cleared by the task itself rather than by the awaiting
    /// callers, so the map can't be left holding a finished task while a later
    /// caller starts a redundant second one.
    private func fetchTileOnce(forKey key: String, url: URL) async -> FetchedTile? {
        let fetch = inFlightFetches.withLock { tasks -> Task<FetchedTile?, Never> in
            if let existing = tasks[key] { return existing }
            let task = Task { [weak self] () -> FetchedTile? in
                guard let self else { return nil }
                let fetched = await self.fetchTile(forKey: key, url: url)
                self.inFlightFetches.withLock { $0[key] = nil }
                return fetched
            }
            tasks[key] = task
            return task
        }
        return await fetch.value
    }

    /// One tile off the network, validated and decoded, with nothing written
    /// anywhere — the caller decides which tier it belongs in. Go through
    /// ``fetchTileOnce(forKey:url:)`` rather than calling this directly.
    private func fetchTile(forKey key: String, url: URL) async -> FetchedTile? {
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
            return FetchedTile(data: data, image: image)
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
        let (cached, durable) = filePaths(forKey: key)
        if freshModificationDate(for: durable) != nil {
            // Already coverage. Any browsing-tier copy is the same bytes over
            // again — most easily produced by a bulk download racing the map's
            // own load of the same tile, which is the *normal* case while
            // downloading the route you're looking at.
            discardRedundantCachedCopy(forKey: key)
            return true
        }
        guard freshModificationDate(for: cached) != nil else { return false }
        do {
            // `moveItem` refuses to overwrite, so clear the destination first.
            // `freshModificationDate` above has already deleted an expired
            // durable copy; this covers one written concurrently since.
            try? FileManager.default.removeItem(at: durable)
            try FileManager.default.moveItem(at: cached, to: durable)
            return true
        } catch {
            // Another renderer may have promoted the same shared tile after
            // the checks above. That is still a successful durable save.
            if freshModificationDate(for: durable) != nil {
                discardRedundantCachedCopy(forKey: key)
                return true
            }
            // Nothing cached to promote — the tile was served from memory after
            // its disk copy went (an OS purge of `Caches`, say). Callers drop
            // their claim, so this is retried next time the tile is drawn.
            #if DEBUG
            Self.logger.debug("No cached tile to save for \(key, privacy: .public)")
            #endif
            return false
        }
    }

    /// Removes expired tiles from both disk tiers, and any browsing-tier copy of
    /// a tile that is also stored durably. Runs at launch so stale offline
    /// coverage is not retained indefinitely.
    ///
    /// The duplicate sweep is what heals an install that already has some: the
    /// write paths no longer produce them, but tiles saved before that stay on
    /// disk in both tiers until something goes looking.
    ///
    /// **Disk only.** This deliberately leaves the memory tier alone. It used to
    /// open with `memory.removeAllObjects()`, before it had looked at a single
    /// date — and since `OpenTrailsApp.init` kicks this off at every launch,
    /// that dropped every tile the map had cached in the milliseconds since
    /// launch, which are by definition the ones on screen. All of them were
    /// then re-read from disk at the moment the app is busiest, to answer with
    /// the same images. ``memoryImage(forKey:)`` applies the same TTL lazily on
    /// read, so an expired tile can't be served from memory either way; the
    /// blanket eviction bought nothing and cost a stampede.
    @discardableResult
    func removeExpiredTiles(referenceDate: Date = Date()) -> Int {
        assertOffMainThread("removeExpiredTiles() enumerates and deletes tile files synchronously — call it off the main thread")

        func isStale(_ file: URL) -> Bool {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // An unreadable date means an unusable tile, so treat it as stale.
            return modified.map { isExpired($0, referenceDate: referenceDate) } ?? true
        }

        func remove(_ file: URL) -> Bool {
            (try? FileManager.default.removeItem(at: file)) != nil
        }

        var removed = 0

        // Durable first, so what survives here is known while walking the
        // browsing tier — where a copy of a surviving durable tile is a
        // duplicate rather than a tile in its own right.
        var keptDurableNames = Set<String>()
        for file in allTileFiles(in: durableDirectory) {
            if isStale(file) {
                if remove(file) { removed += 1 }
            } else {
                keptDurableNames.insert(file.lastPathComponent)
            }
        }

        for file in allTileFiles(in: directory)
        where isStale(file) || keptDurableNames.contains(file.lastPathComponent) {
            if remove(file) { removed += 1 }
        }

        return removed
    }

    /// Writes freshly-fetched bytes straight to durable storage, for the
    /// download path — where there's no cached copy to move.
    private func writeDurable(_ data: Data, forKey key: String) -> Bool {
        do {
            try data.write(to: filePaths(forKey: key).durable, options: .atomic)
            // The map may have written the same tile into the browsing tier
            // while this download was in flight — both writes succeed, and the
            // loser is a second file holding the same bytes under the same key.
            discardRedundantCachedCopy(forKey: key)
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

    /// Enforces the one-file-per-key rule in the one direction it can go wrong:
    /// a browsing-tier copy of a tile that is also stored durably.
    ///
    /// Durable wins because it's the stronger claim — the bytes are identical,
    /// so the only question is which file is allowed to be reclaimed by the OS,
    /// and a hike is counting on the answer being "not this one". Called after
    /// every write, since the map's write and a download's write are ordered
    /// only by chance.
    private func discardRedundantCachedCopy(forKey key: String) {
        let (cached, durable) = filePaths(forKey: key)
        guard FileManager.default.fileExists(atPath: durable.path) else { return }
        try? FileManager.default.removeItem(at: cached)
    }

    /// Where a key's tile may sit, in each tier.
    ///
    /// **At most one of these exists at a time.** The two tiers are where a tile
    /// lives, not two places it lives at once: the same bytes in both would cost
    /// the storage twice and — since both the hike sheet and Settings measure by
    /// key — be *reported* twice on top of that. Every write path below is
    /// responsible for leaving exactly one behind, and the read paths count a
    /// key once regardless, so a duplicate that ever does appear can't inflate a
    /// number the user sees.
    private func filePaths(forKey key: String) -> (cached: URL, durable: URL) {
        let name = diskName(for: key)
        return (
            cached: directory.appendingPathComponent(name),
            durable: durableDirectory.appendingPathComponent(name)
        )
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
    func bytes(forKeys keys: [String]) -> Int64 {
        assertOffMainThread("bytes(forKeys:) stats up to two files per key — call it off the main thread")
        return keys.reduce(0) { total, key in
            let (cached, durable) = filePaths(forKey: key)
            let durableSize = fileSize(durable)
            return total + (durableSize > 0 ? durableSize : fileSize(cached))
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

        // Disk only, for the same reason as `removeExpiredTiles()`: this also
        // runs at launch, and dropping the memory tier would throw away the
        // tiles currently on screen to reclaim space on disk they aren't using.
        // A trimmed tile still in memory draws until it's evicted normally,
        // which is strictly better than refetching it from the provider.
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

    /// Returns a usable fetch date, deleting the file when its fixed TTL has
    /// elapsed. Modification time is the fetch time because tile files are
    /// written atomically and never rewritten except by a fresh response.
    private func freshModificationDate(for file: URL, referenceDate: Date = Date()) -> Date? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, !isExpired(modified, referenceDate: referenceDate) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return modified
    }

    private func isExpired(_ storedAt: Date, referenceDate: Date = Date()) -> Bool {
        referenceDate.timeIntervalSince(storedAt) >= Self.tileExpirationInterval
    }
}
