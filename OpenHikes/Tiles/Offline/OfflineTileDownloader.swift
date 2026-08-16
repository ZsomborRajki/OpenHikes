//
//  OfflineTileDownloader.swift
//  OpenHikes
//
//  Pre-fetches the map tiles covering a route's bounding box across a range of
//  zoom levels and primes `TileCache` with them, so the route can be viewed
//  offline later. Tiles are stored under the exact keys the map renderer looks
//  up (`providerID/z/x/y@scale`), so a warmed cache is served transparently.
//

import CoreLocation
import Foundation
import os

@Observable
final class OfflineTileDownloader {
    /// `nonisolated`: logged from within `group.addTask`, which runs off the
    /// main actor.
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "OfflineDownload")

    enum Phase: Equatable { case idle, downloading, finished, failed(String) }

    private(set) var phase: Phase = .idle
    /// Tiles actually saved so far — not tiles attempted.
    ///
    /// The difference is the whole point: attempts always reach `total`, so a
    /// progress bar driven by them fills to 100% however many tiles were
    /// really written. A bar that stalls is telling the truth about a download
    /// that has stopped saving anything.
    private(set) var completed = 0
    private(set) var total = 0
    /// Coverage produced by the latest completed run. Complete runs omit the
    /// explicit keys; partial runs carry only keys verified on durable storage.
    private(set) var completedRecord: OfflineDownloadRecord?

    /// 0…1 fraction of tiles saved, for a progress indicator.
    var progress: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var task: Task<Void, Never>?
    /// The most recently started run, kept past a `cancel()` that clears
    /// `task`. Only ``waitForCurrentRun()`` reads it: an abandoned run's tail
    /// is exactly what the cancellation tests are about, and without a handle
    /// on it the only way to wait for one is to sleep and hope.
    private var lastRun: Task<Void, Never>?
    /// Continuations parked in ``waitForPlanning()``, resumed by
    /// ``finishPlanning()``.
    private var planningWaiters: [CheckedContinuation<Void, Never>] = []
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
    nonisolated static let tileBudget = 4000
    /// How many tiles are kept in flight in the task group at once — a
    /// pipelining window, not a concurrency cap. What actually limits
    /// simultaneous blocking work is ``TileLoadGate``, shared with the map's
    /// own tile loads; tasks beyond its background share simply park on it.
    /// Keeping this a little wider than that share means there's always one
    /// ready to go the moment a slot frees.
    private let inFlightWindow = 5

    init(
        isOnline: @escaping @Sendable () -> Bool = { TileCache.shared.isOnline },
        saveTile: @escaping @Sendable (String, URL) async -> Bool = { key, url in
            await TileCache.shared.saveTileDurably(forKey: key, url: url)
        }
    ) {
        self.isOnline = isOnline
        self.saveTile = saveTile
    }

    /// Begins preparing and downloading the tiles covering `route` from
    /// `source`, saving detail down to the provider's deepest real zoom level.
    /// Route conversion and tile enumeration stay off the main actor.
    ///
    /// A source whose provider forbids bulk downloads is refused here, not
    /// only where the button is drawn: ``TileProvider/supportsBulkDownload``
    /// is a promise to the tile host rather than a UI affordance, so the code
    /// that would do the fetching has to be the thing that keeps it.
    func start(route: [RouteCoordinate], source: ActiveTileSource, scale: CGFloat) {
        guard phase != .downloading else { return }
        guard source.permitsBulkDownload else {
            phase = .failed("This map source doesn't allow offline downloads.")
            return
        }
        guard route.count > 1 else {
            phase = .failed("No route to save.")
            return
        }
        guard isOnline() else {
            phase = .failed("You're offline — connect to save tiles.")
            return
        }

        generation += 1
        let currentGeneration = generation
        completed = 0
        total = 0
        completedRecord = nil
        phase = .downloading
        let maxZoom = max(source.maximumZ, Self.minZoom)
        task = Task { [weak self] in
            await self?.prepareAndRun(
                route: route,
                source: source,
                maxZoom: maxZoom,
                scale: scale,
                generation: currentGeneration
            )
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
        finishPlanning()
    }

    /// Returns to idle after a finished/failed download (e.g. its tiles were deleted).
    func reset() {
        guard phase != .downloading else { return }
        phase = .idle
        completed = 0
        total = 0
        completedRecord = nil
    }

    private func prepareAndRun(
        route: [RouteCoordinate],
        source: ActiveTileSource,
        maxZoom: Int,
        scale: CGFloat,
        generation: Int
    ) async {
        let tiles: [Tile]
        do throws(CancellationError) {
            tiles = try await Self.plannedTiles(for: route, maxZoom: maxZoom)
        } catch {
            // Planning was cancelled. `cancel()` already moved the phase to
            // `.idle`; anything else that cancelled the task would otherwise
            // strand the UI on "Preparing offline tiles…" forever.
            resetPhaseIfPreparing(generation: generation)
            finishPlanning()
            return
        }
        guard generation == self.generation, !Task.isCancelled else {
            resetPhaseIfPreparing(generation: generation)
            finishPlanning()
            return
        }
        guard !tiles.isEmpty else {
            phase = .failed("Nothing to save.")
            finishPlanning()
            return
        }
        total = tiles.count
        finishPlanning()
        await run(
            tiles: tiles,
            source: source,
            scale: scale,
            generation: generation
        )
    }

    /// Leaves a stale generation alone — a newer `start()` owns the phase — but
    /// never leaves the current run advertising a download that will not begin.
    private func resetPhaseIfPreparing(generation: Int) {
        guard generation == self.generation, phase == .downloading, total == 0 else { return }
        phase = .idle
    }

    private func run(tiles: [Tile], source: ActiveTileSource, scale: CGFloat, generation: Int) async {
        struct SaveResult: Sendable {
            let key: String
            let saved: Bool
        }

        let saveTileCallback = saveTile
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
                    guard let url = tile.url(from: source.urlTemplate)
                    else { return SaveResult(key: key, saved: false) }
                    // Shared with the map's own tile loads, at `.background`:
                    // nobody minds a download taking a minute longer, and
                    // everybody minds the map stalling while it runs.
                    await TileLoadGate.shared.acquire(.background)
                    // Durably, not through `loadTile`: the point of a download is
                    // that the tiles are still there when the user is out of
                    // signal, which rules out the OS-reclaimable cache.
                    let saved = await saveTileCallback(key, url)
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

        finalize(savedKeys: savedKeys, tiles: tiles, source: source, scale: scale, generation: generation)
    }

    private func finalize(
        savedKeys: Set<String>,
        tiles: [Tile],
        source: ActiveTileSource,
        scale: CGFloat,
        generation: Int
    ) {
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
                    ? "Couldn't save any tiles. Check your connection and try again."
                    : "Saved \(sortedKeys.count) of \(tiles.count) tiles. Try again to finish the download."
            )
        }
    }

    /// Test/support hook that waits for the latest run without polling time —
    /// including one that has been cancelled, whose tail is still unwinding.
    func waitForCurrentRun() async {
        await lastRun?.value
    }

    /// Test/support hook that waits until planning has published its tile count
    /// or given up. Continuation-based rather than a `Task.yield()` spin: this
    /// is awaited from the main actor, which is exactly where a spin would
    /// compete with the work it is waiting for.
    func waitForPlanning() async {
        guard phase == .downloading, total == 0 else { return }
        await withCheckedContinuation { continuation in
            planningWaiters.append(continuation)
        }
    }

    /// Releases `waitForPlanning()` waiters. Called on every path that leaves
    /// the planning stage, successfully or not, so a waiter is never stranded.
    private func finishPlanning() {
        let waiters = planningWaiters
        planningWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
