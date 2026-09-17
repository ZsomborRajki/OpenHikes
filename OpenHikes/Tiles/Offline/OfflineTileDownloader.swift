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
    /// What a previous run already saved and claimed for this hike, so this
    /// one neither re-fetches it nor forgets it. Empty for a first attempt.
    private var resumedKeys: Set<String> = []
    /// Keys saved by this run and already committed, so a batch claim sends
    /// only what is new. The merge would union them anyway — this is about not
    /// handing a four-thousand-element array to the store thirty-two times.
    private var claimedKeys: Set<String> = []
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

    /// How many newly saved tiles are claimed at a time.
    ///
    /// **This is the number that decides what a killed run keeps.** A run's
    /// tiles used to be claimed once, at the end, so a process evicted at 90%
    /// of four thousand tiles kept none of them — the next launch trim
    /// reclaims every durable tile no hike claims, and nothing had claimed
    /// these. Claiming as they land caps that loss at this many tiles instead
    /// of the whole run.
    ///
    /// Not smaller, because each claim is a SwiftData `save()` on the main
    /// actor: per tile it would be four thousand commits in a run, which is
    /// the hiker's scrolling paying for the download's durability. Not larger,
    /// because the point is bounding the loss. At 4000 tiles this is at most
    /// 32 commits, and at most 125 tiles lost to a kill.
    nonisolated static let defaultClaimBatchSize = 125

    /// Where this run asks not to be suspended halfway through — see
    /// ``BackgroundTimeReservation``.
    private let backgroundTime: BackgroundTimeReservation
    /// Injectable for the reason the gate and the transport are: a suite
    /// asserting that a run claims *mid-flight* needs a plan with several
    /// batches in it, and the fixture routes plan far fewer tiles than a real
    /// one. Raising the route's size instead would make every such test a
    /// thousand injected saves to watch two commits.
    let claimBatchSize: Int
    /// The grant currently held, so the run can give it back exactly once.
    /// `nil` between runs and for a run the system refused — the same state
    /// as far as `releaseBackgroundTime()` is concerned.
    private var backgroundTimeToken: BackgroundTimeToken?

    init(
        gate: TileLoadGate = .shared,
        isOnline: @escaping @Sendable () -> Bool = { TileCache.shared.isOnline },
        quota: QuotaBroker = .standard,
        registry: OfflineDownloadRegistry = .shared,
        backgroundTime: BackgroundTimeReservation = .default,
        claimBatchSize: Int = defaultClaimBatchSize,
        saveTile: @escaping @Sendable (String, URL) async -> Bool = { key, url in
            await TileCache.shared.saveTileDurably(forKey: key, url: url)
        }
    ) {
        self.gate = gate
        self.isOnline = isOnline
        self.quota = quota
        self.registry = registry
        self.backgroundTime = backgroundTime
        self.claimBatchSize = max(1, claimBatchSize)
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
        alreadySaved: Set<String> = [],
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
        resumedKeys = alreadySaved
        // Seeded rather than started at zero, so the bar measures the map
        // rather than this attempt at it. A resumed run that fetches the last
        // thousand tiles of four thousand has saved four thousand as far as
        // the hiker is concerned, and a progress bar that restarted at zero
        // for the final quarter would be the app forgetting what it kept.
        completed = alreadySaved.count
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
        // Bracketed for MetricKit: what a maximum-budget download costs in
        // CPU, footprint and *logical writes* is a question no Simulator run
        // can answer, because the Simulator writes to a Mac's SSD.
        let span = FieldSignpost.begin(.offlineDownload)
        // Before the task starts rather than inside it, so a hiker who taps
        // Save and locks the phone in the same second is already covered.
        reserveBackgroundTime()
        task = Task { [weak self] in
            defer { FieldSignpost.end(span) }
            await self?.prepareAndRun(
                route: route,
                source: source,
                maxZoom: maxZoom,
                generation: currentGeneration
            )
            // Whatever the run did — finished, failed, was superseded or was
            // cancelled out from under itself — the grant goes back here.
            // Holding one after the work has stopped is how an app gets
            // killed on the next expiry instead of suspended.
            self?.releaseBackgroundTime()
        }
        lastRun = task
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
        // **The gap, not the plan.** The whole grid is what the map needs and
        // is what `total` counts; what this run has to *fetch* is whatever a
        // previous run did not already put on disk and claim. Filtered after
        // planning rather than instead of it, because the plan is what says
        // how big the map is — a resumed run that measured itself against the
        // gap would report a four-thousand-tile map as a thousand-tile one.
        let plannedCount = tiles.count
        let outstanding = tiles.filter { !resumedKeys.contains($0.cacheKey(providerID: source.providerID)) }
        total = plannedCount
        finishPlanning()

        guard !outstanding.isEmpty else {
            // Everything this run was asked for is already on disk and already
            // claimed, which is a finished download rather than an empty one.
            // Reachable when a run was killed on its last batch.
            phase = .finished
            return
        }

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
            tiles: outstanding,
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
        claimedKeys = []

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
                    completed = resumedKeys.count + savedKeys.count
                }
                // Claimed as they land, which is the whole of this change: a
                // process evicted between here and `finalize` used to cost the
                // hiker every tile the run had fetched.
                if savedKeys.count - claimedKeys.count >= claimBatchSize {
                    guard claimBatch(of: savedKeys, source: source) else {
                        // The store refused. Carrying on would spend the
                        // hiker's connection on tiles nothing can claim — and
                        // the next launch trim deletes exactly those — so the
                        // run stops here rather than at the end.
                        group.cancelAll()
                        break
                    }
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

    /// Publishes what the run produced, and commits who it belongs to first.
    ///
    /// The order is the point: every tile counted here is already on durable
    /// storage, where the next launch trim deletes whatever no hike claims. A
    /// phase saying the map was saved, published ahead of the claim, is a
    /// promise a refused commit — or a hike deleted while this ran — has
    /// already broken. See ``OfflineDownloadClaim``.
    ///
    /// **This is no longer the only claim a run makes** — see
    /// ``claimBatch(of:source:)`` — but it is still the only one that
    /// *promises* anything, and it is the only one that can produce the
    /// complete record. Two consequences worth knowing:
    ///
    /// - `tiles` is the outstanding gap rather than the whole plan, so
    ///   `isComplete` asks whether this run closed the gap. Gap closed plus
    ///   whatever a previous run claimed is the whole route, which is why the
    ///   complete record — the one that re-derives the grid and supersedes
    ///   every partial — is still correct to write here.
    /// - A cancelled run claims nothing *further*. What its batches already
    ///   committed stays committed, because those tiles are genuinely on disk
    ///   and a resumed run should not pay for them twice. The most a cancel
    ///   can strand is one batch.
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

// MARK: - Claiming coverage as it lands

/// The batch claim, in a same-file extension.
///
/// `OfflineTileDownloader` is at SwiftLint's `type_body_length` limit — PR
/// #484 moved `cancel()` out for the same reason — and this is the member that
/// tipped it over again. Same file rather than a neighbouring one because
/// `private` is file-scoped: an extension elsewhere could not reach
/// `claimedKeys` or `claim`.
extension OfflineTileDownloader {
    /// Commits the keys saved since the last batch, and says whether it stuck.
    ///
    /// **The phase is untouched, and that is the invariant surviving the
    /// change.** "A phase saying the map was saved is published after the
    /// claim" used to be a statement about the one claim a run made; there are
    /// now many, and restating it per batch would have each batch announcing
    /// something. It does not: during a run the phase is ``Phase/downloading``,
    /// which promises nothing, and the only promise — ``Phase/finished`` — is
    /// still made once, in `finalize`, after the last claim. What the batches
    /// change is *durability*, not what the hiker is told.
    ///
    /// Partial by construction: a batch lists exact keys, so it can never be
    /// mistaken for the complete record that re-derives the whole grid. The
    /// complete one, when the run earns it, replaces the partials through
    /// ``Hike/mergeOfflineDownload(_:)``.
    private func claimBatch(of savedKeys: Set<String>, source: ActiveTileSource) -> Bool {
        let pending = savedKeys.subtracting(claimedKeys)
        guard !pending.isEmpty, let claim else { return true }
        let record = OfflineDownloadRecord(
            providerID: source.providerID,
            maxZoom: source.maximumZ,
            savedTileKeys: pending.sorted()
        )
        do {
            try claim(record)
        } catch {
            return false
        }
        claimedKeys.formUnion(pending)
        return true
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
}

// MARK: - Stopping, and the background time a run holds

// An extension rather than more of the class above, which is at its
// `type_body_length` limit — the same way out `OpenHikesView` takes, and in
// the same file so these stay beside the run they bracket. Same-file
// extensions reach the type's `private` members, so nothing had to be opened
// up to move them here.
extension OfflineTileDownloader {
    /// Stops the current run and puts everything back to rest.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
        completed = 0
        total = 0
        completedRecord = nil
        pendingRun = nil
        // Forgotten, not undone. The batches this run already committed stay
        // committed — those tiles are on disk and a later run should not pay
        // for them twice — but this downloader is no longer mid-run, so the
        // next `start()` is told afresh what the hike already has.
        resumedKeys = []
        claimedKeys = []
        // Given back here as well as in the task's tail: a cancelled task's
        // tail is not guaranteed to run promptly and the system is counting.
        // Both paths are idempotent.
        releaseBackgroundTime()
        finishPlanning()
    }

    /// Asks the system not to suspend this run, and remembers the grant.
    ///
    /// A refusal is not a failure: background execution can be unavailable,
    /// and the download then behaves exactly as it did before this existed —
    /// it stalls on lock and resumes on return. Nothing is reported, because
    /// there is nothing the hiker could do about it.
    private func reserveBackgroundTime() {
        // A run already holding one is a run being restarted. Give the old
        // grant back first rather than leaking it: the system counts them,
        // and an unreturned task is charged against the app either way.
        releaseBackgroundTime()
        backgroundTimeToken = backgroundTime.begin { [weak self] in
            // The system is about to reclaim the time. Stopping is not
            // optional here — an app still running when the grant expires is
            // killed rather than suspended, and a killed run is the one
            // outcome that costs the hiker every tile it fetched.
            self?.cancel()
        }
    }

    /// Gives the grant back, once.
    ///
    /// Idempotent by clearing the token before spending it, which is what
    /// lets both the task's tail and ``cancel()`` call it without the second
    /// one ending a task the system has already reclaimed.
    private func releaseBackgroundTime() {
        guard let token = backgroundTimeToken else { return }
        backgroundTimeToken = nil
        backgroundTime.end(token)
    }
}
