//
//  TileCache.swift
//  OpenHikes
//
//  Two-tier (memory + disk) tile cache with async network loading.
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

/// Receives connectivity callbacks from ``TileCache``, always on the main queue.
/// Renderers adopt this to retry tiles once the network is back.
/// A reconnect listener. `Sendable` because ``TileCache`` holds these across
/// the network monitor's queue and the main thread: the notification is raised
/// off-main and delivered on-main, so the reference itself crosses an
/// isolation boundary even though every call to it lands on the main thread.
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

    /// Whether the user has allowed map tiles over cellular. Cached here
    /// rather than read from `UserDefaults` per tile: this is consulted on
    /// every miss, from a background queue, and a defaults read is a real call
    /// rather than a field access. ``setAllowsCellularDownloads(_:)`` keeps it
    /// in step with the settings screen.
    let cellularAllowed: Mutex<Bool>

    /// Reads the device's power state for the fetch policy. See `init`.
    let readPower: @Sendable () -> PowerState

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
    private let inFlightFetches = Mutex([String: Task<FetchedTile?, Never>]())

    private struct MutationToken: Equatable {
        let global: UInt64
        let key: UInt64
    }

    /// Orders disk/memory writes against explicit deletion. A fetch captures
    /// a token before awaiting the network; deleting that key invalidates the
    /// token so the late response cannot put the tile back.
    let mutationVersions: Mutex<MutationVersions>

    /// Weakly-held reconnect listeners. A boxed array keeps the reference weak so
    /// a deallocated renderer drops out without needing to unregister.
    struct WeakObserver: Sendable { weak var value: TileCacheObserver? }

    let observers = Mutex([WeakObserver]())

    let monitor = NWPathMonitor()
    private let monitorsNetwork: Bool

    /// OSM's tile usage policy requires an identifying User-Agent. Named so a
    /// test can assert on the header the app really sends rather than on a
    /// copy of the string.
    static let userAgent = "OpenHikes/1.0 (iOS; hiking app)"

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
    ///   - mutationKeyLimit: how many per-key deletion versions are held
    ///     before the table is compacted. A test lowers it to reach
    ///     compaction in a handful of deletions.
    ///   - readPower: how the fetch policy learns whether the device is
    ///     conserving. Injected rather than read from ``PowerState/current``
    ///     directly because that snapshot is process-wide: a suite that
    ///     published a Low Power Mode reading would otherwise change what
    ///     every other suite running beside it decided about the network.
    init(
        storageRoot: URL? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil,
        monitorsNetwork: Bool = true,
        mutationKeyLimit: Int = TileCache.mutationKeyVersionLimit,
        defaults: UserDefaults = .standard,
        readPower: @escaping @Sendable () -> PowerState = { .current }
    ) {
        self.readPower = readPower
        mutationVersions = Mutex(MutationVersions(keyLimit: mutationKeyLimit))
        cellularAllowed = Mutex(
            defaults.object(forKey: SettingsKey.cellularTileDownloads) as? Bool
                ?? SettingsDefault.cellularTileDownloads
        )
        let cacheRoot = storageRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appSupportURLs = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )
        let durableRoot = storageRoot ?? appSupportURLs[0]
        directory = cacheRoot.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        durableDirectory = durableRoot.appendingPathComponent(Self.durableDirectoryName, isDirectory: true)
        Self.createDirectoryIfNeeded(at: directory)
        Self.createDirectoryIfNeeded(at: durableDirectory)

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

    static func tileSessionConfiguration(
        from configuration: URLSessionConfiguration? = nil
    ) -> URLSessionConfiguration {
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A backstop under ``TileNetworkPolicy``, not a substitute for it. The
        // policy stops the request before a connection is opened, which is
        // what saves the radio; this makes sure that a path that somehow
        // reaches here still cannot spend a Low Data Mode allowance on a map
        // tile. There is no matching `allowsExpensiveNetworkAccess = false`
        // because the cellular decision is a user setting that changes while
        // the session lives, and a configuration is read once.
        config.allowsConstrainedNetworkAccess = false
        return config
    }

    deinit {
        if monitorsNetwork { monitor.cancel() }
    }
}

nonisolated extension TileCache {

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
        // swiftlint:disable:next legacy_objc_type
        memory.setObject(tile, forKey: key as NSString, cost: tile.byteCost)
    }

    func memoryImage(forKey key: String, referenceDate: Date = Date()) -> TileImage? {
        // swiftlint:disable:next legacy_objc_type
        let cacheKey = key as NSString
        guard let tile = memory.object(forKey: cacheKey) else {
            return nil
        }
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
    @discardableResult func loadTile(
        forKey key: String,
        url: URL,
        purpose: TileFetchPurpose = .interactive
    ) async -> TileImage? {
        let mutationToken = mutationToken(forKey: key)
        if let cached = memoryImage(forKey: key) {
            return cached
        }

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
            ) else {
                return nil
            }
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

        guard let fetched = await fetchTileOnce(forKey: key, url: url)
        else {
            return nil
        }
        // Back into the tier it came from. A tile that was durable is offline
        // coverage some hike is counting on; writing its replacement to the
        // browsing tier instead would leave the manifest still claiming it while
        // the OS is free to reclaim it — and, before this wrote to one tier
        // rather than always to `directory`, left the expired durable copy
        // sitting alongside the new one as a second file for the same key.
        guard storeFetchedTile(
            fetched,
            forKey: key,
            at: wasDurable ? paths.durable : paths.cached,
            token: mutationToken
        ) else {
            return nil
        }
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
    @discardableResult func saveTileDurably(forKey key: String, url: URL) async -> Bool {
        let mutationToken = mutationToken(forKey: key)
        // Already saved by an earlier download or by auto-save, or already
        // browsed and so sitting on disk in the wrong tier: either way, no
        // reason to ask the tile server for a second copy.
        if promoteCachedTile(forKey: key) {
            return true
        }

        let decision = networkDecision(for: .speculative)
        guard decision.isAllowed else {
            RenderSignpost.mark(
                "TileFetchSuppressed",
                "purpose=speculative reason=\(decision.reason ?? "unknown")"
            )
            return false
        }
        guard let fetched = await fetchTileOnce(forKey: key, url: url)
        else {
            return false
        }
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
        for tier in [directory, durableDirectory] {
            let file = tier.appendingPathComponent(name)
            guard let storedAt = freshModificationDate(for: file) else { continue }
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
            if let existing = tasks[key] {
                return existing
            }
            let task = Task { [weak self] () -> FetchedTile? in
                guard let self else {
                    return nil
                }
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
        mutationVersions.withLock { versions in
            MutationToken(
                global: versions.global,
                key: versions.keys[key, default: 0]
            )
        }
    }

    private func storeFetchedTile(
        _ fetched: FetchedTile,
        forKey key: String,
        at destination: URL,
        token: MutationToken
    ) -> Bool {
        mutationVersions.withLock { versions in
            guard token == MutationToken(
                global: versions.global,
                key: versions.keys[key, default: 0]
            ) else {
                return false
            }
            do {
                try fetched.data.write(to: destination, options: .atomic)
            } catch {
                logFileError(
                    error,
                    operation: "write cached tile",
                    url: destination
                )
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
        mutationVersions.withLock { versions in
            guard token == MutationToken(
                global: versions.global,
                key: versions.keys[key, default: 0]
            ) else {
                return false
            }
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
        mutationVersions.withLock { versions in
            guard token == MutationToken(
                global: versions.global,
                key: versions.keys[key, default: 0]
            ) else {
                return false
            }
            cacheInMemory(fetched.image, storedAt: Date(), forKey: key)
            return writeDurable(fetched.data, forKey: key)
        }
    }

    /// One tile off the network, validated and decoded, with nothing written
    /// anywhere — the caller decides which tier it belongs in. Go through
    /// ``fetchTileOnce(forKey:url:)`` rather than calling this directly.
    private static let httpSuccessRange = 100 * 2..<100 * 3

    private func fetchTile(forKey key: String, url: URL) async -> FetchedTile? {
        #if DEBUG
        Self.logger.debug("Requesting tile \(key, privacy: .public) from \(url.absoluteString, privacy: .public)")
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
                #if DEBUG
                let tileErrMsg = "Tile \(key) failed: HTTP \(http.statusCode)"
                    + " (\(data.count)b) from \(url.absoluteString)"
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
    @discardableResult func promoteCachedTile(forKey key: String) -> Bool {
        mutationVersions.withLock { _ in
            let (cached, durable) = filePaths(forKey: key)
            if freshModificationDate(for: durable) != nil {
                // Already coverage. Any browsing-tier copy is the same bytes
                // over again.
                discardRedundantCachedCopy(forKey: key)
                return true
            }
            guard freshModificationDate(for: cached) != nil else {
                return false
            }
            do {
                // `moveItem` refuses to overwrite, so clear the destination
                // first. A missing destination is the expected case.
                _ = removeItemIgnoringNotFound(
                    at: durable,
                    operation: "replace durable tile"
                )
                try FileManager.default.moveItem(at: cached, to: durable)
                return true
            } catch {
                // Another writer may have produced the durable copy after the
                // checks above. That is still a successful save.
                if freshModificationDate(for: durable) != nil {
                    discardRedundantCachedCopy(forKey: key)
                    return true
                }
                #if DEBUG
                Self.logger.debug(
                    // swiftlint:disable:next line_length
                    "No cached tile to save for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                #endif
                return false
            }
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
        guard FileManager.default.fileExists(atPath: durable.path) else {
            return
        }
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
