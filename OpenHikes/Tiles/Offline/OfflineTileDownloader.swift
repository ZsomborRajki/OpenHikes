//
//  OfflineTileDownloader.swift
//  OpenHikes
//
//  Pre-fetches the map tiles covering a route's bounding box across a range of
//  zoom levels and primes `TileCache` with them, so the route can be viewed
//  offline later. Tiles are stored under the exact keys the map renderer looks
//  up (`providerID/z/x/y`), so a warmed cache is served transparently.
//

import CoreLocation
import Foundation
import os

@Observable
final class OfflineTileDownloader {
    /// `nonisolated`: logged from within `group.addTask`, which runs off the
    /// main actor.
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "OfflineDownload")

    enum Phase: Equatable {
        case idle
        case downloading
        /// Planned, but the provider's durable ceiling has no room for it.
        /// Waits for the user to approve freeing space — see
        /// ``confirmReclaimingSpace()`` — or to cancel. Nothing has been
        /// fetched or deleted at this point.
        case needsSpace(SpaceShortfall)
        case finished
        case failed(String)
    }

    /// A plan held while the user decides whether to free space for it.
    struct PendingRun {
        let tiles: [Tile]
        let source: ActiveTileSource
        let shortfall: SpaceShortfall
        let generation: Int
    }

    /// How a run records the coverage it verified, against the hike that
    /// asked for it — see ``OfflineDownloadClaim``.
    ///
    /// Bound at ``start(route:source:claim:)`` rather than read back when the
    /// run ends, which is what gives ownership a lifetime of its own: the
    /// hike is decided by the tap, and the download keeps writing durable
    /// tiles long after the screen that started it has been dismissed. A
    /// closure rather than the ``Hike`` itself so this stays a tile
    /// subsystem — the store, its sidecar and the merge rule live on the
    /// other side of the seam, the same way the transport and the save do.
    typealias Claim = @MainActor (OfflineDownloadRecord) throws(OfflineDownloadClaim.Failure) -> Void

    /// What one tile's task carries back out of the group. `nonisolated`, like
    /// ``Tile``, because it crosses out of a child task.
    nonisolated private struct SaveResult: Sendable {
        let key: String
        let saved: Bool
    }

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
    /// Injectable for the same reason the transport is: the app's gate is a
    /// singleton shared with the map, and a suite that measured this
    /// downloader's own in-flight window through it would be measuring
    /// whatever else happened to be loading tiles at the time.
    private let gate: TileLoadGate
    private let saveTile: @Sendable (String, URL) async -> Bool
    /// Where this downloader announces a run, so the storage actions that
    /// delete durable tiles can stand it down first — see
    /// ``OfflineDownloadRegistry``.
    private let registry: OfflineDownloadRegistry
    /// Where the current run's coverage is recorded, handed over by the
    /// `start` that began it and outliving whatever screen that was. `nil`
    /// until the first download, which is the only state in which a finished
    /// run has nothing to claim to.
    private var claim: Claim?
    let quota: QuotaBroker
    /// A plan waiting on the space confirmation. Cleared by every path that
    /// leaves ``Phase/needsSpace(_:)``.
    var pendingRun: PendingRun?

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
    nonisolated static let inFlightWindow = 5

    init(
        gate: TileLoadGate = .shared,
        isOnline: @escaping @Sendable () -> Bool = { TileCache.shared.isOnline },
        quota: QuotaBroker = .standard,
        registry: OfflineDownloadRegistry = .shared,
        saveTile: @escaping @Sendable (String, URL) async -> Bool = { key, url in
            await TileCache.shared.saveTileDurably(forKey: key, url: url)
        }
    ) {
        self.gate = gate
        self.isOnline = isOnline
        self.quota = quota
        self.registry = registry
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
    /// - Parameter claim: Where this run's verified coverage is recorded and
    ///   committed when it ends — see ``Claim``. Required rather than
    ///   defaulted: a download whose tiles nothing claims is one the next
    ///   launch trim deletes, so every caller has to say where the map it is
    ///   about to spend a connection on belongs.
    func start(
        route: [RouteCoordinate],
        source: ActiveTileSource,
        claim: @escaping Claim
    ) {
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
        pendingRun = nil
        self.claim = claim
        phase = .downloading
        // Announced before the first tile is planned, so a deletion that
        // starts while this run is in flight stands it down rather than
        // racing its completion for the manifest.
        registry.track(self)
        let maxZoom = max(source.maximumZ, Self.minZoom)
        // Bracketed for MetricKit rather than for `RenderSignpost`: what a
        // maximum-budget download costs in CPU, footprint and *logical writes*
        // on a real phone is the one item in `PERFORMANCE.md`'s "Validating on
        // a device" list that no simulator run can answer, because the
        // simulator writes to a Mac's SSD.
        let span = FieldSignpost.begin(.offlineDownload)
        task = Task { [weak self] in
            defer { FieldSignpost.end(span) }
            await self?.prepareAndRun(
                route: route,
                source: source,
                maxZoom: maxZoom,
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
        pendingRun = nil
        finishPlanning()
    }

    private func prepareAndRun(
        route: [RouteCoordinate],
        source: ActiveTileSource,
        maxZoom: Int,
        generation: Int
    ) async {
        let tiles: [Tile]
        do throws(CancellationError) {
            tiles = try await Self.plannedTiles(
                for: route,
                maxZoom: maxZoom,
                providerID: source.providerID
            )
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

        // A provider whose terms cap durable storage may not have room for
        // this. Asked before a single tile is fetched, so a user who declines
        // has cost nothing and lost nothing.
        if let shortfall = await spaceShortfall(tiles: tiles, source: source) {
            guard generation == self.generation, !Task.isCancelled else { return }
            pendingRun = PendingRun(
                tiles: tiles,
                source: source,
                shortfall: shortfall,
                generation: generation
            )
            phase = .needsSpace(shortfall)
            return
        }

        await run(
            tiles: tiles,
            source: source,
            generation: generation
        )
    }

    /// Frees the space the pending download needs and starts it.
    ///
    /// The only caller is the confirmation raised by ``Phase/needsSpace(_:)``,
    /// and it is the only thing in the app that authorizes deleting offline
    /// coverage a hike still claims.
    func confirmReclaimingSpace() {
        guard case .needsSpace = phase, let pending = pendingRun else { return }
        pendingRun = nil
        phase = .downloading
        task = Task { [weak self] in
            guard let self else { return }
            let plannedKeys = Set(
                pending.tiles.map { tile in
                    tile.cacheKey(providerID: pending.source.providerID)
                }
            )
            _ = await quota.reclaim(
                pending.source.providerID,
                plannedKeys,
                pending.shortfall.bytesToFree
            )
            guard pending.generation == generation, !Task.isCancelled else { return }
            await run(
                tiles: pending.tiles,
                source: pending.source,
                generation: pending.generation
            )
        }
        lastRun = task
    }

    /// Leaves a stale generation alone — a newer `start()` owns the phase — but
    /// never leaves the current run advertising a download that will not begin.
    private func resetPhaseIfPreparing(generation: Int) {
        guard generation == self.generation, phase == .downloading, total == 0 else { return }
        phase = .idle
    }

    private func run(tiles: [Tile], source: ActiveTileSource, generation: Int) async {
        let saveTileCallback = saveTile
        let loadGate = gate
        var savedKeys = Set<String>()

        await withTaskGroup(of: SaveResult.self) { group in
            var pending = tiles.makeIterator()

            // The window is one task in for every result out, rather than an
            // in-flight tally kept by hand. `withDiscardingTaskGroup` would be
            // shorter still, but it has no `next()` to hang the refill off, and
            // an unbounded `addTask` loop would put the whole tile budget on
            // the host at once.
            func addNext() {
                guard let tile = pending.next() else { return }
                group.addTask {
                    await Self.save(
                        tile,
                        from: source,
                        through: loadGate,
                        using: saveTileCallback
                    )
                }
            }

            for _ in 0..<Self.inFlightWindow { addNext() }

            for await result in group {
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

        await finalize(savedKeys: savedKeys, tiles: tiles, source: source, generation: generation)
    }

    /// One tile, fetched straight into durable storage. `nonisolated static`
    /// because it is the body of a task-group child: it runs off the main
    /// actor, and taking everything it needs as parameters is what keeps it
    /// from capturing the observable downloader along with them.
    nonisolated private static func save(
        _ tile: Tile,
        from source: ActiveTileSource,
        through gate: TileLoadGate,
        using saveTile: @Sendable (String, URL) async -> Bool
    ) async -> SaveResult {
        let key = tile.cacheKey(providerID: source.providerID)
        guard let url = tile.url(from: source.urlTemplate) else { return SaveResult(key: key, saved: false) }
        // Shared with the map's own tile loads, at `.background`: nobody minds
        // a download taking a minute longer, and everybody minds the map
        // stalling while it runs.
        await gate.acquire(.background)
        // Re-checked on the far side of the gate, which is where a tile can
        // sit for a while behind the map: a download the user stopped in the
        // meantime must not still put its queued requests on the wire.
        var saved = false
        if !Task.isCancelled {
            // Durably, not through `loadTile`: the point of a download is that
            // the tiles are still there when the user is out of signal, which
            // rules out the OS-reclaimable cache.
            saved = await saveTile(key, url)
        }
        await gate.release(.background)
        #if DEBUG
        if saved {
            Self.logger.debug("Bulk-saved tile \(key, privacy: .public)")
        }
        #endif
        return SaveResult(key: key, saved: saved)
    }

    /// Publishes what the run produced, and commits who it belongs to first.
    ///
    /// The order is the point: every tile counted here is already on durable
    /// storage, where the next launch trim deletes whatever no hike claims. A
    /// phase saying the map was saved, published ahead of the claim, is a
    /// promise a refused commit — or a hike deleted while this ran — has
    /// already broken. See ``OfflineDownloadClaim``.
    private func finalize(
        savedKeys: Set<String>,
        tiles: [Tile],
        source: ActiveTileSource,
        generation: Int
    ) async {
        guard generation == self.generation else { return }
        guard !Task.isCancelled else {
            phase = .idle
            return
        }

        let sortedKeys = savedKeys.sorted()
        let isComplete = savedKeys.count == tiles.count
        let record = Self.coverage(
            savedKeys: sortedKeys,
            plannedCount: tiles.count,
            source: source
        )
        completedRecord = record

        if let record {
            do {
                try claim?(record)
            } catch {
                phase = .failed(Self.unclaimedMessage)
                return
            }
        }

        guard !isComplete else {
            phase = .finished
            return
        }
        phase = .failed(
            await failureMessage(
                savedCount: sortedKeys.count,
                plannedCount: tiles.count,
                source: source
            )
        )
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
