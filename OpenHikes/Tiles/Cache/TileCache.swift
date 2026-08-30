//
//  TileCache.swift
//  OpenHikes
//
//  Three-tier (memory, ephemeral disk, durable disk) tile cache with async
//  network loading.
//

import Foundation
import MapKit
import Network
import os
import Synchronization

#if canImport(UIKit)
import UIKit
typealias TileImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias TileImage = NSImage
#endif

/// A reconnect listener. Renderers adopt this to retry tiles once the network
/// is back; the callback always lands on the main queue.
///
/// `Sendable` because ``TileCache`` holds these across the network monitor's
/// queue and the main thread: the notification is raised off-main and
/// delivered on-main, so the reference itself crosses an isolation boundary
/// even though every call to it lands on the main thread.
protocol TileCacheObserver: AnyObject, Sendable {
    func tileCacheDidReconnect()
}

/// Caches map tiles in memory (`NSCache`) and on disk, fetching missing tiles
/// over the network. Safe to call from any thread/task.
///
/// `@unchecked` because of `memory`: `NSCache` is thread-safe but is not
/// declared `Sendable` by the SDK, and there is no Swift-native equivalent
/// with cost-based eviction to replace it. Every other stored property is
/// either immutable or a `Mutex`, and so `Sendable` on its own — the
/// annotation covers the `NSCache` and nothing else.
nonisolated final class TileCache: @unchecked Sendable {
    static let shared = TileCache(
        // A UI test that claims the app works offline must not have that claim
        // decided by the machine it runs on — nor by what a *previous* run
        // left on disk. An offline scenario therefore gets its own empty
        // storage root, so every visible tile is a genuine miss and the
        // refusals it asserts on are real. See
        // ``AppLaunchEnvironment/simulatesOffline``.
        storageRoot: AppLaunchEnvironment.simulatesOffline
            ? AppLaunchEnvironment.isolatedTileRoot()
            : nil,
        monitorsNetwork: !AppLaunchEnvironment.simulatesOffline
    )

    static let logger = Logger(subsystem: "OpenHikes", category: "TileRequests")

    private static let maintenanceQueue = DispatchQueue(
        label: "com.openhikes.tile-cache-maintenance",
        qos: .utility
    )

    /// Runs synchronous cache maintenance serially away from the main thread.
    static func scheduleMaintenance(
        _ operation: @escaping @Sendable () -> Void
    ) {
        Task.detached(executorPreference: maintenanceQueue) {
            operation()
        }
    }

    /// Runs synchronous cache maintenance off-main and returns its result.
    static func performMaintenance<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await Task.detached(executorPreference: maintenanceQueue) {
            operation()
        }.value
    }

    /// `@unchecked` because of `image`: `TileImage` (`UIImage`/`NSImage`) is
    /// not declared `Sendable`, though a decoded tile is never mutated after
    /// construction. The other two properties are immutable value types.
    final class MemoryTile: @unchecked Sendable {
        let image: TileImage
        let storedAt: Date
        /// What this entry costs the memory tier — see
        /// ``TileCache/decodedByteCost(of:)``. Computed once, at insertion.
        let byteCost: Int

        init(image: TileImage, storedAt: Date) {
            self.image = image
            self.storedAt = storedAt
            byteCost = TileCache.decodedByteCost(of: image)
        }
    }

    /// Bytes the decoded bitmap for `image` occupies.
    ///
    /// The number that matters, and not the one the cache used to be bounded
    /// by. A tile arrives as a compressed PNG of a few tens of kilobytes and
    /// is held as an uncompressed bitmap: every raster template in
    /// ``TileProvider`` asks for a plain 256×256 tile — none of them carries a
    /// scale placeholder — so a tile decodes to 256×256×4 bytes, 256 KB, five
    /// to ten times its file size. Counting *tiles* therefore said little
    /// about the memory being used, and nothing at all about a decode that
    /// came back a different size.
    ///
    /// Which is why this measures the bitmap rather than assuming one. A
    /// provider template that later asks for a retina tile is charged the four
    /// times as much it costs, with nothing here to update.
    static func decodedByteCost(of image: TileImage) -> Int {
        #if canImport(UIKit)
        let bitmap = image.cgImage
        #elseif canImport(AppKit)
        let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        if let bitmap, bitmap.bytesPerRow > 0, bitmap.height > 0 { return bitmap.bytesPerRow * bitmap.height }
        // No backing bitmap to measure. Estimate from the point size at four
        // bytes a pixel rather than charging nothing, which would exempt the
        // entry from the limit entirely — `NSCache` treats a zero cost as free.
        return max(Int(image.size.width * image.size.height * 4), 1)
    }

    /// One tile off the network: the bytes exactly as served, plus the decoded
    /// image. `@unchecked Sendable` for the same reason ``MemoryTile`` is —
    /// `TileImage` isn't `Sendable`, and a decoded tile is never mutated after
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
    /// 512 tiles, at the 256 KB every raster provider actually serves. A
    /// screenful is eight or so tiles on a phone, so this is deep pan and zoom
    /// headroom: the level either side of the one being read stays resident
    /// for the zoom back, and the lower-zoom ancestors the overzoom fallback
    /// draws while children load are never the thing evicted.
    ///
    /// Deliberately left at 128 MB rather than trimmed to the working set.
    /// This is a ceiling, not a reservation — a session reaches it only after
    /// sustained browsing, and `NSCache` evicts under memory pressure before
    /// the app is the one killed for it. What the ceiling buys on the way
    /// there is refetches not made over a connection a walker may not have.
    ///
    /// The tier was previously bounded only by `countLimit = 1_024`, an
    /// effective ceiling of 256 MB — twice this, and expressed in a unit that
    /// says nothing about the resource being spent. That count limit survives
    /// as a backstop for pathologically small tiles; at any real tile size the
    /// byte limit is the one that binds.
    static let memoryByteLimit = 64 * 2 * 1024 * 1024

    // swiftlint:disable:next legacy_objc_type
    let memory = NSCache<NSString, MemoryTile>()
    let directory: URL
    /// Durable (non-purgeable) store for tiles the user has explicitly chosen to
    /// keep, e.g. via ``AutoSaveTileStore``. Unlike `directory`, this lives under
    /// Application Support, so it survives OS storage-pressure cache eviction.
    let durableDirectory: URL
    private let session: URLSession

    /// Live network conditions, updated by `NWPathMonitor`. Tile loads short-
    /// circuit on these, so an offline app doesn't fire (and log) a doomed
    /// request for every visible tile — and a metered or Low Data Mode
    /// connection doesn't quietly become the most expensive part of a hike.
    let conditions = Mutex(TileNetworkConditions())
    var isOnline: Bool { conditions.withLock { $0.isOnline } }
    var networkConditions: TileNetworkConditions { conditions.withLock { $0 } }

    /// Reads the device's power state for the fetch policy. See `init`.
    let readPower: @Sendable () -> PowerState

    /// Network fetches currently in flight, keyed by cache key.
    ///
    /// The map and the bulk downloader reach the network through different
    /// entry points — ``loadTile(forKey:url:purpose:)`` and
    /// ``saveTileDurably(forKey:url:)`` — so downloading the area you're
    /// looking at had both asking the provider for every tile independently.
    /// That doubles the request load on servers whose usage policies are the
    /// reason this app has an auto-save mechanism at all.
    ///
    /// Keyed by cache key rather than URL: the key is what both callers already
    /// agree identifies a tile, and it's what the tiers file it under.
    private let inFlightFetches = Mutex([String: Task<FetchedTile?, Never>]())

    private struct MutationToken: Equatable {
        let global: UInt64
        let name: UInt64
    }

    /// Orders disk/memory writes against explicit deletion. A fetch captures
    /// a token before awaiting the network; deleting that tile invalidates the
    /// token so the late response cannot put the tile back. Keyed by disk
    /// name — see ``MutationVersions/names``.
    let mutationVersions: Mutex<MutationVersions>

    /// Weakly-held reconnect listeners. A boxed array keeps the reference weak so
    /// a deallocated renderer drops out without needing to unregister.
    struct WeakObserver: Sendable { weak var value: TileCacheObserver? }

    let observers = Mutex([WeakObserver]())

    let monitor = NWPathMonitor()
    private let monitorsNetwork: Bool

    /// Durable bytes held per provider id, for the providers whose terms cap
    /// them. Measured lazily by one directory walk and maintained
    /// incrementally after; see `TileCache+DurableQuota.swift`.
    ///
    /// Its own lock rather than a field under `mutationVersions`: the walk that
    /// fills it must not happen with that lock held, for the same reason
    /// `trimCache` does not enumerate under it. Where both are taken,
    /// `mutationVersions` is the outer one — never the reverse.
    let durableProviderBytes = Mutex<[String: Int64]>([:])
    /// See the `durableByteLimitScale` parameter on ``init``.
    let durableByteLimitScale: Double

    /// Deadlines tile servers have asked for through `Retry-After`, read back
    /// by the renderer when the load they belong to fails. See
    /// ``TileRetryAdvice``.
    let retryAdvice = Mutex(TileRetryAdvice())

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
    ///   - mutationKeyLimit: how many per-tile deletion versions are held
    ///     before the table is compacted. A test lowers it to reach
    ///     compaction in a handful of deletions.
    ///   - readPower: how the fetch policy learns whether the device is
    ///     conserving. Injected rather than read from ``PowerState/current``
    ///     directly because that snapshot is process-wide: a suite that
    ///     published a Low Power Mode reading would otherwise change what
    ///     every other suite running beside it decided about the network.
    ///   - durableByteLimitScale: shrinks every provider's durable ceiling by
    ///     this factor. `1` — the app — enforces the real figure the terms
    ///     set; a test passes something tiny so it can reach the ceiling with
    ///     a handful of tiles instead of a hundred megabytes. Scaled rather
    ///     than replaced, so a provider whose terms set no ceiling still has
    ///     none.
    init(
        storageRoot: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        monitorsNetwork: Bool = true,
        mutationKeyLimit: Int = TileCache.mutationKeyVersionLimit,
        durableByteLimitScale: Double = 1,
        readPower: @escaping @Sendable () -> PowerState = { .current }
    ) {
        self.readPower = readPower
        self.durableByteLimitScale = durableByteLimitScale
        mutationVersions = Mutex(MutationVersions(keyLimit: mutationKeyLimit))
        let cacheRoot = storageRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appSupportURLs = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )
        let durableRoot = storageRoot ?? appSupportURLs[0]
        directory = cacheRoot.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        durableDirectory = durableRoot.appendingPathComponent(Self.durableDirectoryName, isDirectory: true)
        Self.createDirectoryIfNeeded(at: directory)
        Self.createDirectoryIfNeeded(at: durableDirectory, excludeFromBackup: true)

        let config = Self.tileSessionConfiguration(from: sessionConfiguration)
        session = URLSession(configuration: config)

        memory.totalCostLimit = Self.memoryByteLimit
        // A secondary backstop, kept for the pathological case of very small
        // tiles. The byte limit is what binds at any real tile size.
        memory.countLimit = 1024

        self.monitorsNetwork = monitorsNetwork
        if monitorsNetwork {
            startMonitoringNetwork()
        } else if AppLaunchEnvironment.simulatesOffline {
            // A cache with no monitor otherwise keeps the optimistic default,
            // which is right for a unit test driving `setReachable(_:)` and
            // exactly wrong for the launch argument that asked to be offline.
            conditions.withLock { $0.isOnline = false }
        }
    }

    deinit {
        if monitorsNetwork { monitor.cancel() }
    }
}

nonisolated extension TileCache {

    /// Puts a tile in the memory tier, charged at its decoded size.
    ///
    /// The single insertion point on purpose: `setObject(_:forKey:)` without a
    /// cost enters as free, and one call site that forgot would quietly exempt
    /// its tiles from ``memoryByteLimit`` — with no symptom until the app is
    /// killed for memory somewhere else entirely.
    private func cacheInMemory(_ image: TileImage, storedAt: Date, forKey key: String) {
        let tile = MemoryTile(image: image, storedAt: storedAt)
        // swiftlint:disable:next legacy_objc_type
        memory.setObject(tile, forKey: key as NSString, cost: tile.byteCost)
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
    func memoryImage(forKey key: String, referenceDate: Date = Date()) -> TileImage? {
        // swiftlint:disable:next legacy_objc_type
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
    /// - Parameter purpose: whether the map is drawing this tile now, which is
    ///   what ``TileNetworkPolicy`` weighs against the connection's cost.
    ///   Defaults to `.interactive`, because the only caller that isn't is the
    ///   bulk downloader, and it goes through `saveTileDurably` anyway.
    ///
    /// `@concurrent` rather than plain `nonisolated`: everything below the
    /// first memory hit is synchronous disk work, and an `async` function that
    /// inherits its caller's isolation would run all of it on the main actor
    /// for any caller that happens to be there. A render miss must not become
    /// main-thread I/O, so the hop is in the callee rather than trusted to
    /// every call site.
    @concurrent
    @discardableResult func loadTile(
        forKey key: String,
        url: URL,
        purpose: TileFetchPurpose = .interactive
    ) async -> TileImage? {
        assertOffMainThread(
            "loadTile(forKey:url:purpose:) stats and reads tile files synchronously — call it off the main thread"
        )
        let mutationToken = mutationToken(forKey: key)
        if let cached = memoryImage(forKey: key) { return cached }

        // Which tier holds this key, read *before* `diskImage` — it deletes an
        // expired file as it finds it, and the answer decides where a refetched
        // tile is written back below.
        let paths = filePaths(forKey: key)
        let wasDurable = FileManager.default.fileExists(atPath: paths.durable.path)

        if let tile = diskImage(forKey: key) {
            guard publishDiskTile(
                tile,
                forKey: key,
                token: mutationToken
            ) else { return nil }
            return tile.image
        }

        // Offline, metered, or asked to conserve: the tile isn't cached and
        // opening a connection for it is either doomed or unwanted. Return
        // without requesting so we don't spam failing loads for every visible
        // tile, and mark it so the reason is in the signpost stream rather
        // than only in a debug log nobody is reading on a mountain.
        let decision = networkDecision(for: purpose)
        guard decision.isAllowed else {
            RenderSignpost.mark(
                "TileFetchSuppressed",
                "purpose=\(purpose.rawValue) reason=\(decision.reason ?? "unknown")"
            )
            #if DEBUG
            Self.logger.debug(
                "Skipped tile \(key, privacy: .public): \(decision.reason ?? "", privacy: .public)"
            )
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
        guard storeFetchedTile(
            fetched,
            forKey: key,
            in: wasDurable ? .durable : .browsing,
            token: mutationToken
        ) else { return nil }
        return fetched.image
    }

    /// Fetches a tile straight into durable storage — the bulk-download path.
    ///
    /// The counterpart to ``loadTile(forKey:url:purpose:)``: same network fetch, but the
    /// bytes land where the OS can't reclaim them. A download is coverage the
    /// user explicitly asked for, and `Caches` is the first thing purged under
    /// storage pressure — a tile evicted from under a saved hike is offline
    /// coverage that silently isn't there when they're out of signal.
    ///
    /// Returns whether the tile is durably saved once this returns.
    ///
    /// `@concurrent` for the same reason as ``loadTile(forKey:url:purpose:)``:
    /// the move and the write are synchronous, so the hop belongs here.
    @concurrent
    @discardableResult func saveTileDurably(forKey key: String, url: URL) async -> Bool {
        assertOffMainThread(
            "saveTileDurably(forKey:url:) moves and writes tile files synchronously — call it off the main thread"
        )
        let mutationToken = mutationToken(forKey: key)
        // Already saved by an earlier download or by auto-save, or already
        // browsed and so sitting on disk in the wrong tier: either way, no
        // reason to ask the tile server for a second copy.
        if promoteCachedTile(forKey: key) { return true }

        // At the provider's durable ceiling the fetch below could only be
        // thrown away again, so stop before it reaches the network rather than
        // after. Without this a download at the cap would fetch every one of
        // its remaining tiles and discard each — the exact traffic the
        // provider's limit exists to prevent.
        guard !isDurableLimitReached(forKey: key) else {
            RenderSignpost.mark("TileDurableLimitReached", "key=\(key)")
            return false
        }

        let decision = networkDecision(for: .speculative)
        guard decision.isAllowed else {
            RenderSignpost.mark(
                "TileFetchSuppressed",
                "purpose=speculative reason=\(decision.reason ?? "unknown")"
            )
            return false
        }
        guard let fetched = await fetchTileOnce(forKey: key, url: url) else { return false }
        return storeFetchedTileDurably(
            fetched,
            forKey: key,
            token: mutationToken
        )
    }

    /// The tile as it sits on disk, ephemeral tier first — it's the one a
    /// browsing fetch refreshes, and the two hold the same image.
    private func diskImage(forKey key: String) -> (image: TileImage, storedAt: Date)? {
        let name = diskName(for: key)
        for tier in [StorageTier.browsing, .durable] {
            let file = directory(for: tier).appendingPathComponent(name)
            guard let storedAt = freshModificationDate(for: file, in: tier) else { continue }
            do {
                let data = try Data(contentsOf: file)
                guard let image = TileImage(data: data) else {
                    Self.logger.error(
                        "Cached tile could not be decoded at \(file.path, privacy: .public)"
                    )
                    continue
                }
                return (image, storedAt)
            } catch {
                logFileError(
                    error,
                    operation: "read cached tile",
                    url: file
                )
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
                let fetched = await fetchTile(forKey: key, url: url)
                inFlightFetches.withLock { $0[key] = nil }
                return fetched
            }
            tasks[key] = task
            return task
        }
        return await fetch.value
    }

    private func mutationToken(forKey key: String) -> MutationToken {
        let name = diskName(for: key)
        return mutationVersions.withLock { versions in
            Self.mutationToken(forName: name, in: versions)
        }
    }

    /// The one place a tile's row in ``MutationVersions`` is located, so the
    /// site that takes a token and the three that re-check one cannot drift
    /// apart on how a key becomes a row.
    ///
    /// By disk name, because that is what the paths that *delete* have:
    /// ``trimCache(claimedBy:limit:)`` and
    /// ``reclaimDurableBytes(forProviderID:protecting:byteCount:)`` enumerate
    /// files, and ``diskName(for:)`` is one-way. Nothing is lost by meeting
    /// them there — see ``MutationVersions/names``.
    ///
    /// Call with ``mutationVersions`` held.
    private static func mutationToken(
        forName name: String,
        in versions: MutationVersions
    ) -> MutationToken {
        MutationToken(global: versions.global, name: versions.names[name, default: 0])
    }

    /// Files freshly-fetched bytes in `tier` and publishes them to memory,
    /// unless the key was deleted while the fetch was in flight.
    ///
    /// A durable write here is a *refresh* of coverage that already exists —
    /// ``loadTile(forKey:url:purpose:)`` only reaches it for a key that was
    /// durable before the fetch — so the provider's total is moved by what
    /// this write actually changes rather than gated by
    /// ``reserveDurableBytes(forKey:byteCount:)``. Reserving would be the
    /// obvious symmetry with ``storeFetchedTileDurably(_:forKey:token:)`` and
    /// is the wrong call: a reservation can refuse, and a refusal here returns
    /// `nil` from a *browse*, so the tile the walker is looking at goes blank
    /// and the coverage their hike claims is gone for good, on a key whose
    /// bytes were counted against the ceiling a moment earlier. That trades an
    /// accounting drift for a functional regression. The ceiling still gates
    /// every genuinely new durable tile — ``saveTileDurably(forKey:url:)`` and
    /// ``promoteCachedTile(forKey:)`` both reserve — and
    /// ``enforceDurableByteLimits()`` corrects a store that is over it.
    ///
    /// The delta, rather than the tile's whole size, because the destination
    /// may still hold a counted file: a durable tile that is present but
    /// undecodable is not deleted by the TTL check, and this write replaces
    /// it. Adding the full size there would count one tile twice.
    private func storeFetchedTile(
        _ fetched: FetchedTile,
        forKey key: String,
        in tier: StorageTier,
        token: MutationToken
    ) -> Bool {
        let paths = filePaths(forKey: key)
        let name = diskName(for: key)
        let destination = tier == .durable ? paths.durable : paths.cached
        return mutationVersions.withLock { versions in
            guard token == Self.mutationToken(forName: name, in: versions) else { return false }
            let previousBytes = tier == .durable ? fileSize(destination) : 0
            do {
                try fetched.data.write(to: destination, options: .atomic)
                if tier == .durable {
                    adjustDurableBytes(
                        forProviderID: Self.providerID(forKey: key),
                        by: Int64(fetched.data.count) - previousBytes
                    )
                }
            } catch {
                logFileError(error, operation: "write cached tile", url: destination)
            }
            // A download sharing this fetch may have filed the same bytes in
            // durable storage. Durable wins, so reconcile before publishing
            // the memory entry under the same mutation lock.
            discardRedundantCachedCopy(forKey: key)
            cacheInMemory(fetched.image, storedAt: Date(), forKey: key)
            return true
        }
    }

    private func publishDiskTile(
        _ tile: (image: TileImage, storedAt: Date),
        forKey key: String,
        token: MutationToken
    ) -> Bool {
        let name = diskName(for: key)
        return mutationVersions.withLock { versions in
            guard token == Self.mutationToken(forName: name, in: versions) else { return false }
            cacheInMemory(
                tile.image,
                storedAt: tile.storedAt,
                forKey: key
            )
            return true
        }
    }

    private func storeFetchedTileDurably(
        _ fetched: FetchedTile,
        forKey key: String,
        token: MutationToken
    ) -> Bool {
        let byteCount = Int64(fetched.data.count)
        let name = diskName(for: key)
        // Outside the lock, since taking the provider's first measurement
        // walks the durable directory.
        guard reserveDurableBytes(forKey: key, byteCount: byteCount) else { return false }
        let stored = mutationVersions.withLock { versions in
            guard token == Self.mutationToken(forName: name, in: versions) else { return false }
            cacheInMemory(fetched.image, storedAt: Date(), forKey: key)
            return writeDurable(fetched.data, forKey: key)
        }
        if !stored { releaseDurableBytes(forKey: key, byteCount: byteCount) }
        return stored
    }

    private static let httpSuccessRange = 100 * 2..<100 * 3

    /// One tile off the network, validated and decoded, with nothing written
    /// anywhere — the caller decides which tier it belongs in. Go through
    /// ``fetchTileOnce(forKey:url:)`` rather than calling this directly.
    private func fetchTile(forKey key: String, url: URL) async -> FetchedTile? {
        #if DEBUG
        Self.logger.debug("Requesting tile \(key, privacy: .public) from \(url.redactedForLogging, privacy: .public)")
        #endif
        // The counter an offline-first app is judged on. Everything else in
        // this file is about *not* reaching here; this is the one place that
        // does, so a scenario's tile traffic is exactly this signpost's count.
        let interval = RenderSignpost.beginInterval("TileNetworkFetch")
        defer { RenderSignpost.endInterval("TileNetworkFetch", interval) }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                #if DEBUG
                Self.logger.error("Tile \(key, privacy: .public): response was not HTTP")
                #endif
                return nil
            }
            guard Self.httpSuccessRange.contains(http.statusCode) else {
                // A 429 or an overloaded 503 is the one failure that comes
                // with its own answer to "when should I come back". Filed
                // here, applied by the renderer's existing backoff — nothing
                // in this file waits on it.
                recordRetryAdvice(from: http, forKey: key)
                #if DEBUG
                let tileErrMsg = "Tile \(key) failed: HTTP \(http.statusCode)"
                    + " (\(data.count)b) from \(url.redactedForLogging)"
                Self.logger.error("\(tileErrMsg, privacy: .public)")
                #endif
                return nil
            }
            guard let image = TileImage(data: data) else {
                #if DEBUG
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                let tileDecodeErr = "Tile \(key) failed: undecodable"
                    + " (\(data.count)b HTTP \(http.statusCode) \(contentType))"
                Self.logger.error("\(tileDecodeErr, privacy: .public)")
                #endif
                return nil
            }

            #if DEBUG
            Self.logger.debug("Fetched tile \(key, privacy: .public) (\(data.count, privacy: .public) bytes)")
            #endif
            return FetchedTile(data: data, image: image)
        } catch {
            #if DEBUG
            let reqErr = error.localizedDescription
            Self.logger.error("Tile \(key, privacy: .public) request failed: \(reqErr, privacy: .public)")
            #endif
            return nil
        }
    }

    /// Moves the browsing cache's copy of a tile into durable storage, keeping
    /// the bytes exactly as the tile server sent them. Used by
    /// ``AutoSaveTileStore`` for tiles the user has already viewed, and so
    /// already fetched through ``loadTile(forKey:url:purpose:)``, which is what put that
    /// cached copy there.
    ///
    /// A move, not a re-encode. Providers serve PNG, which is already both a
    /// lossless and a compact representation of flat-filled, sharp-edged
    /// cartography, so re-encoding buys nothing — and moving the file keeps a
    /// decode and an encode off the drawing path entirely.
    ///
    /// Returns whether the tile is durably stored once this returns — including
    /// when it already was, which is what lets a second hike over the same
    /// ground claim tiles the first one saved.
    ///
    /// Refuses when the provider is at its ``TileProvider/durableByteLimit``.
    /// The tile keeps its browsing-tier copy and still draws; it simply isn't
    /// promoted to coverage. ``AutoSaveTileStore`` treats that refusal exactly
    /// as it treats a missing cached copy — the claim is given back, so the
    /// tile is reconsidered rather than recorded as saved.
    ///
    /// - Parameter racingWriter: **test seam**, like `referenceDate` elsewhere
    ///   in this file. Runs in the window between the two tier checks below —
    ///   the interleaving where another writer promoting the same key moves
    ///   the cached copy out from under this call. Only a scheduler can open
    ///   that window in production, and a test that waits for one to open by
    ///   chance is not a regression test.
    @discardableResult func promoteCachedTile(
        forKey key: String,
        racingWriter: () -> Void = { /* no-op */ }
    ) -> Bool {
        assertOffMainThread(
            "promoteCachedTile(forKey:) stats and moves tile files synchronously — call it off the main thread"
        )
        let paths = filePaths(forKey: key)
        // Bytes already durable are already counted against the ceiling, so
        // this case must not reserve any. Checked before the lock so the
        // reservation below — which may walk the durable directory to take its
        // first measurement — is never taken with `mutationVersions` held.
        if freshModificationDate(for: paths.durable, in: .durable) != nil {
            return mutationVersions.withLock { _ in
                discardRedundantCachedCopy(forKey: key)
                return true
            }
        }
        racingWriter()
        guard freshModificationDate(for: paths.cached, in: .browsing) != nil else {
            // No cached copy is not the same answer as "not saved". A racer
            // promoting the same key moves that copy away, and between the
            // durable check above and this one it can complete the move —
            // leaving this call looking at a key with neither a cached copy
            // nor (as it last looked) a durable one. Reporting `false` there
            // makes ``AutoSaveTileStore`` give back a claim whose bytes are on
            // disk: the tile is saved, the hike no longer owns it, and nothing
            // reconsiders it because the browsing copy it would be re-saved
            // from is gone. The move is a rename, so a missing cached copy
            // means it has already landed.
            return freshModificationDate(for: paths.durable, in: .durable) != nil
        }

        let byteCount = fileSize(paths.cached)
        guard reserveDurableBytes(forKey: key, byteCount: byteCount) else { return false }

        // `alreadyDurable` exists so the reservation this call took is given
        // back: another writer's bytes are already counted, and counting them
        // twice would spend the ceiling on one tile.
        enum Outcome { case alreadyDurable, failed, stored }

        let outcome = mutationVersions.withLock { _ -> Outcome in
            // Re-checked under the lock. The pre-lock check above is only an
            // optimisation — it keeps the measurement walk out of the lock —
            // and two writers racing one key can both pass it. Without this,
            // the destination clear below would delete the durable tile the
            // other writer just wrote, and then report that nothing was saved.
            if freshModificationDate(for: paths.durable, in: .durable) != nil {
                discardRedundantCachedCopy(forKey: key)
                return .alreadyDurable
            }
            do {
                // `moveItem` refuses to overwrite, so clear the destination
                // first. A missing destination is the expected case.
                _ = removeItemIgnoringNotFound(
                    at: paths.durable,
                    operation: "replace durable tile"
                )
                try FileManager.default.moveItem(at: paths.cached, to: paths.durable)
                return .stored
            } catch {
                // Another writer may have produced the durable copy after the
                // checks above. That is still a successful save.
                if freshModificationDate(for: paths.durable, in: .durable) != nil {
                    discardRedundantCachedCopy(forKey: key)
                    return .alreadyDurable
                }
                #if DEBUG
                Self.logger.debug(
                    // swiftlint:disable:next line_length
                    "No cached tile to save for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                #endif
                return .failed
            }
        }

        switch outcome {
        case .stored:
            return true
        case .alreadyDurable:
            releaseDurableBytes(forKey: key, byteCount: byteCount)
            return true
        case .failed:
            releaseDurableBytes(forKey: key, byteCount: byteCount)
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
    /// date — and since `OpenHikesApp.init` kicks this off at every launch,
    /// that dropped every tile the map had cached in the milliseconds since
    /// launch, which are by definition the ones on screen. All of them were
    /// then re-read from disk at the moment the app is busiest, to answer with
    /// the same images. ``memoryImage(forKey:)`` applies the same TTL lazily on
    /// read, so an expired tile can't be served from memory either way; the
    /// blanket eviction bought nothing and cost a stampede.
    @discardableResult func removeExpiredTiles(referenceDate: Date = Date()) -> Int {
        assertOffMainThread(
            "removeExpiredTiles() enumerates and deletes tile files synchronously — call it off the main thread"
        )

        func isStale(_ file: URL) -> Bool {
            // A fresh stat, not the one `allTileFiles` prefetched. Enumerating
            // with `includingPropertiesForKeys:` caches the modification date
            // on the URL, and `resourceValues` hands that cached value back —
            // which would defeat the lock below by answering with a date read
            // before the lock was taken.
            var file = file
            file.removeAllCachedResourceValues()
            let modified: Date?
            do {
                modified = try file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            } catch {
                logFileError(
                    error,
                    operation: "read tile modification date",
                    url: file
                )
                modified = nil
            }
            // An unreadable date means an unusable tile, so treat it as stale.
            return modified.map { isExpired($0, referenceDate: referenceDate) } ?? true
        }

        func remove(_ file: URL) -> Bool {
            removeItemIgnoringNotFound(
                at: file,
                operation: "remove expired tile"
            )
        }

        var removed = 0

        // Durable first, so what survives here is known while walking the
        // browsing tier — where a copy of a surviving durable tile is a
        // duplicate rather than a tile in its own right.
        //
        // Each stat-and-unlink pair is taken under `mutationVersions`, and
        // deliberately not the enumeration, which would hold the lock for a
        // full directory walk. ``promoteCachedTile(forKey:)`` moves a
        // browsing-tier file into durable storage while holding the same lock,
        // so unlocked these were two syscalls a promote could land between:
        // the sweep stats a seven-day-stale tile, the user re-views it, the
        // promote writes fresh bytes, and the sweep then unlinks them while
        // the key stays in the hike's manifest — a silent hole in a claimed
        // hike's offline coverage. It self-heals on the next draw, which is
        // why this is low rather than high, but nothing else here is holding
        // that lock for show.
        var keptDurableNames = Set<String>()
        for file in allTileFiles(in: durableDirectory) {
            let isKept = mutationVersions.withLock { _ -> Bool in
                guard isStale(file) else { return true }
                if remove(file) { removed += 1 }
                return false
            }
            if isKept { keptDurableNames.insert(file.lastPathComponent) }
        }

        for file in allTileFiles(in: directory) {
            mutationVersions.withLock { _ in
                guard isStale(file) || keptDurableNames.contains(file.lastPathComponent)
                else { return }
                if remove(file) { removed += 1 }
            }
        }

        if removed > 0 { invalidateDurableMeasurements() }
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
            let saveErrDesc = error.localizedDescription
            Self.logger.error("Save tile \(key, privacy: .public) failed: \(saveErrDesc, privacy: .public)")
            #endif
            return false
        }
    }

    func diskName(for key: String) -> String {
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
    func discardRedundantCachedCopy(forKey key: String) {
        let (cached, durable) = filePaths(forKey: key)
        guard FileManager.default.fileExists(atPath: durable.path) else { return }
        _ = removeItemIgnoringNotFound(
            at: cached,
            operation: "remove redundant cached tile"
        )
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
    func filePaths(forKey key: String) -> (cached: URL, durable: URL) {
        let name = diskName(for: key)
        return (
            cached: directory.appendingPathComponent(name),
            durable: durableDirectory.appendingPathComponent(name)
        )
    }
}
