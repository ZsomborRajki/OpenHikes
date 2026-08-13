//
//  OfflineTileDownloader.swift
//  OpenTrails
//
//  Pre-fetches the map tiles covering a route's bounding box across a range of
//  zoom levels and primes `TileCache` with them, so the route can be viewed
//  offline later. Tiles are stored under the exact keys the map renderer looks
//  up (`providerID/z/x/y@scale`), so a warmed cache is served transparently.
//

import Foundation
import CoreLocation
import os

@MainActor
@Observable
final class OfflineTileDownloader {
    /// `nonisolated`: logged from within `group.addTask`, which runs off the
    /// main actor.
    private nonisolated static let logger = Logger(subsystem: "OpenTrails", category: "OfflineDownload")

    enum Phase: Equatable { case idle, downloading, finished, failed(String) }

    private(set) var phase: Phase = .idle
    /// Tiles actually saved so far — not tiles attempted.
    ///
    /// The difference is the whole point: attempts always reach `total`, so a
    /// download that saved nothing still filled its progress bar to 100% and
    /// then reported "Saved 0 of 4,000 tiles." A bar that stalls is telling the
    /// truth about a download that has stopped saving anything.
    private(set) var completed = 0
    private(set) var total = 0
    /// Coverage produced by the latest completed run. Complete runs omit the
    /// explicit keys; partial runs carry only keys verified on durable storage.
    private(set) var completedRecord: OfflineDownloadRecord?

    /// 0…1 fraction of tiles saved, for a progress indicator.
    var progress: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }

    var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private var task: Task<Void, Never>?
    /// The most recently started run, kept past a `cancel()` that clears
    /// `task`. Only ``waitForCurrentRun()`` reads it: an abandoned run's tail
    /// is exactly what the cancellation tests are about, and without a handle
    /// on it the only way to wait for one is to sleep and hope.
    private var lastRun: Task<Void, Never>?
    /// Bumped on every `start()`/`cancel()` so a stale `run()` from a prior,
    /// cancelled download can tell it's no longer current and skip mutating
    /// state that now belongs to a newer download.
    private var generation = 0
    private let isOnline: @Sendable () -> Bool
    private let saveTile: @Sendable (String, URL) async -> Bool

    /// The shallowest zoom to save (whole-route overview). `nonisolated`: a
    /// plain constant read from the `nonisolated` tile-enumeration functions.
    nonisolated static let minZoom = 10
    /// Soft cap on tiles — deeper zoom levels are dropped once exceeded, so a huge
    /// route doesn't try to fetch hundreds of thousands of tiles.
    nonisolated static let tileBudget = 4_000
    /// How many tiles are kept in flight in the task group at once — a
    /// pipelining window, not a concurrency cap. What actually limits
    /// simultaneous blocking work is ``TileLoadGate``, shared with the map's
    /// own tile loads; tasks beyond its background share simply park on it.
    /// Keeping this a little wider than that share means there's always one
    /// ready to go the moment a slot frees.
    private let inFlightWindow = 5

    init(
        isOnline: @escaping @Sendable () -> Bool = { TileCache.shared.isOnline },
        saveTile: @escaping @Sendable (String, URL) async -> Bool = {
            await TileCache.shared.saveTileDurably(forKey: $0, url: $1)
        }
    ) {
        self.isOnline = isOnline
        self.saveTile = saveTile
    }

    /// Begins downloading the tiles covering `route` from `source`, saving detail
    /// down to the provider's deepest real zoom level. `scale` must be the
    /// display scale so cache keys match what the renderer requests on-device.
    func start(route: [CLLocationCoordinate2D], source: ActiveTileSource, scale: CGFloat) {
        guard phase != .downloading else { return }
        guard route.count > 1 else { phase = .failed("No route to save."); return }
        guard isOnline() else { phase = .failed("You're offline — connect to save tiles."); return }

        let tiles = Self.tiles(
            covering: route,
            minZoom: Self.minZoom,
            maxZoom: max(source.maximumZ, Self.minZoom),
            budget: Self.tileBudget
        )
        guard !tiles.isEmpty else { phase = .failed("Nothing to save."); return }

        generation += 1
        let currentGeneration = generation
        completed = 0
        total = tiles.count
        completedRecord = nil
        phase = .downloading
        task = Task { [weak self] in
            await self?.run(tiles: tiles, source: source, scale: scale, generation: currentGeneration)
        }
        lastRun = task
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
        completed = 0
        total = 0
        completedRecord = nil
    }

    /// Returns to idle after a finished/failed download (e.g. its tiles were deleted).
    func reset() {
        guard phase != .downloading else { return }
        phase = .idle
        completed = 0
        total = 0
        completedRecord = nil
    }

    private func run(tiles: [Tile], source: ActiveTileSource, scale: CGFloat, generation: Int) async {
        struct SaveResult: Sendable {
            let key: String
            let saved: Bool
        }

        let saveTile = self.saveTile
        var index = 0
        var savedKeys = Set<String>()

        await withTaskGroup(of: SaveResult.self) { group in
            var active = 0

            func addNext() {
                guard index < tiles.count else { return }
                let tile = tiles[index]
                index += 1
                active += 1
                group.addTask {
                    let key = tile.cacheKey(providerID: source.providerID, scale: scale)
                    guard let url = tile.url(from: source.urlTemplate) else {
                        return SaveResult(key: key, saved: false)
                    }
                    // Shared with the map's own tile loads, at `.background`:
                    // nobody minds a download taking a minute longer, and
                    // everybody minds the map stalling while it runs.
                    await TileLoadGate.shared.acquire(.background)
                    // Durably, not through `loadTile`: the point of a download is
                    // that the tiles are still there when the user is out of
                    // signal, which rules out the OS-reclaimable cache.
                    let saved = await saveTile(key, url)
                    await TileLoadGate.shared.release(.background)
                    #if DEBUG
                    if saved {
                        Self.logger.debug("Bulk-saved tile \(key, privacy: .public)")
                    }
                    #endif
                    return SaveResult(key: key, saved: saved)
                }
            }

            for _ in 0..<min(inFlightWindow, tiles.count) { addNext() }

            while active > 0 {
                guard let result = await group.next() else { break }
                active -= 1
                // A newer download has started since this task began — stop touching
                // its state and let the group drain/cancel our remaining children.
                guard generation == self.generation else {
                    group.cancelAll()
                    break
                }
                // Kept in step with `savedKeys` rather than counted separately,
                // so the bar and the "Saved N of M" message can't disagree.
                if result.saved, savedKeys.insert(result.key).inserted {
                    completed = savedKeys.count
                }
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                addNext()
            }
        }

        guard generation == self.generation else { return }
        guard !Task.isCancelled else {
            phase = .idle
            return
        }

        let sortedKeys = savedKeys.sorted()
        if savedKeys.count == tiles.count {
            completedRecord = OfflineDownloadRecord(
                providerID: source.providerID,
                scale: Double(scale),
                maxZoom: source.maximumZ
            )
            phase = .finished
        } else {
            if !sortedKeys.isEmpty {
                completedRecord = OfflineDownloadRecord(
                    providerID: source.providerID,
                    scale: Double(scale),
                    maxZoom: source.maximumZ,
                    savedTileKeys: sortedKeys
                )
            }
            phase = .failed(
                sortedKeys.isEmpty
                    ? "Couldn’t save any tiles. Check your connection and try again."
                    : "Saved \(sortedKeys.count) of \(tiles.count) tiles. Try again to finish the download."
            )
        }
    }

    /// Test/support hook that waits for the latest run without polling time —
    /// including one that has been cancelled, whose tail is still unwinding.
    func waitForCurrentRun() async {
        await lastRun?.value
    }

    // MARK: - Stored-tile bookkeeping

    /// The cache keys for every tile a download of `route` would produce for the
    /// given provider/scale/depth — so stored tiles can be measured and removed
    /// after the fact. Deterministic: recomputing yields exactly the saved set.
    nonisolated static func tileKeys(for route: [CLLocationCoordinate2D], providerID: String, providerMaxZoom: Int, maxZoom: Int, scale: CGFloat) -> [String] {
        let clamped = min(max(maxZoom, minZoom), providerMaxZoom)
        return tiles(covering: route, minZoom: minZoom, maxZoom: clamped, budget: tileBudget)
            .map { $0.cacheKey(providerID: providerID, scale: scale) }
    }

    /// Pure, `nonisolated` core, taking plain values instead of a `Hike` so it
    /// can run off the main actor. Enumerating tiles across every
    /// recorded download is real CPU work (trig per tile, up to `tileBudget`
    /// tiles each), so callers that do this repeatedly (e.g. re-measuring
    /// storage as auto-save drains in new keys) must not run it on the main
    /// thread — see ``HikeDetailView/refreshStoredBytes()``.
    nonisolated static func storedTileKeys(route: [CLLocationCoordinate2D], offlineDownloads: [OfflineDownloadRecord]) -> [String] {
        assertOffMainThread("storedTileKeys(route:offlineDownloads:) does O(tileBudget) trig work per download record — call it off the main thread")
        guard !offlineDownloads.isEmpty else { return [] }
        var keys = Set<String>()
        for record in offlineDownloads {
            if let savedTileKeys = record.savedTileKeys {
                keys.formUnion(savedTileKeys)
                continue
            }
            let provider = TileProvider.provider(id: record.providerID)
            keys.formUnion(tileKeys(
                for: route,
                providerID: record.providerID,
                providerMaxZoom: provider.maximumZ,
                maxZoom: record.maxZoom,
                scale: CGFloat(record.scale)
            ))
        }
        return Array(keys)
    }

    // MARK: - Tile enumeration

    struct Tile {
        let z: Int
        let x: Int
        let y: Int

        nonisolated func url(from template: String) -> URL? {
            let filled = template
                .replacingOccurrences(of: "{z}", with: String(z))
                .replacingOccurrences(of: "{x}", with: String(x))
                .replacingOccurrences(of: "{y}", with: String(y))
            return URL(string: filled)
        }

        nonisolated func cacheKey(providerID: String, scale: CGFloat) -> String {
            TileCacheKey.namespaced(
                providerID: providerID,
                z: z,
                x: x,
                y: y,
                scale: scale
            )
        }
    }

    /// Enumerates the tiles covering the route's bounding box from the overview
    /// zoom up, stopping before a zoom level that would blow the tile budget.
    private nonisolated static func tiles(covering route: [CLLocationCoordinate2D], minZoom: Int, maxZoom: Int, budget: Int) -> [Tile] {
        guard maxZoom >= minZoom, let box = TileBoundingBox(route: route) else { return [] }

        // A route too sprawling for even the overview zoom to fit the budget
        // gets a shallower overview rather than nothing at all: the budget has
        // to bind here too (this is where a continental route used to blow
        // straight through it), but returning empty would surface as "Nothing to
        // save." for a route that has plenty worth saving. Each level down is a
        // quarter of the tiles, so this bottoms out within a level or two — and
        // at zoom 0 the whole world is one tile.
        var overviewZoom = minZoom
        while overviewZoom > 0, box.tileCount(at: overviewZoom) > budget {
            overviewZoom -= 1
        }

        var tiles: [Tile] = []
        var running = 0
        for z in overviewZoom...maxZoom {
            let count = box.tileCount(at: z)
            guard running + count <= budget else { break }

            let n = 1 << z
            let (firstColumn, columnCount) = box.columns(at: z)
            let (firstRow, rowCount) = box.rows(at: z)
            for column in 0..<columnCount {
                // Columns wrap: a route across the antimeridian runs off the east
                // edge of the grid and continues at column zero.
                let x = SlippyTileMath.wrap(firstColumn + column, to: n)
                for row in 0..<rowCount {
                    tiles.append(Tile(z: z, x: x, y: firstRow + row))
                }
            }
            running += count
        }
        return tiles
    }
}
