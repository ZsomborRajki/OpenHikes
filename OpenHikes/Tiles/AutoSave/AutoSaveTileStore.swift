//
//  AutoSaveTileStore.swift
//  OpenHikes
//
//  Passively persists tiles for the one hike currently being auto-saved, as a
//  side effect of tiles MapKit already fetched to draw on screen — no bulk
//  enumeration, no extra network requests. This is how a provider that
//  disallows automated bulk downloading, and is not cut by country, saves
//  anything at all, and it doubles as a gap-filler for bulk-download-capable
//  providers: any tile the bulk pass missed still gets saved the moment it's
//  actually browsed.
//
//  A tile a downloaded country holds is left alone. It draws with no signal
//  already, out of the country's own files, so a copy kept here would be the
//  same ground on disk twice, counted against the hike's cap.
//
//  A tile the map draws out of memory is offered too, though no load found
//  it: one drawn before the switch went on, or before the hike was selected,
//  is still there when the hiker pans back over it. The draw pass only asks
//  and queues; one worker off it does the disk work.
//

import CoreLocation
import Foundation
import os
import Synchronization

/// Thread-safe singleton bridging the (background) tile-load path to the one
/// hike the user currently has auto-save turned on for. Safe to call from any
/// thread/task, mirroring ``TileCache``.
nonisolated final class AutoSaveTileStore: Sendable {
    static let shared = AutoSaveTileStore()

    private static let logger = Logger(subsystem: "OpenHikes", category: "AutoSaveTiles")

    /// Soft per-hike cap. Smaller than the bulk downloader's budget (4,000)
    /// since this accrues silently across many casual sessions rather than one
    /// deliberate action.
    static let tileCap = 3000
    /// How far past the route's bounding box a tile is still fair game to save.
    static let corridorBufferMeters: CLLocationDistance = 1500

    private struct ActiveHike {
        let id: UUID
        var corridor: TileCorridor
        var acceptsNewClaims: Bool
        /// Every key already known to belong to this hike (loaded from its saved
        /// manifest, plus anything persisted so far this session) — the dedupe +
        /// cap-counting set.
        var knownKeys: Set<String>
        /// Subset of `knownKeys` persisted this session but not yet drained back
        /// into the `Hike`'s SwiftData manifest.
        var pendingKeys: Set<String>
        /// Keys the draw pass has queued from memory for this hike, so a tile
        /// ``considerPersisting(key:z:x:y:)`` turns down — a country's, or one
        /// held in memory alone — is not queued again on every pass. Emptied
        /// when the hike takes claims again after a suspension, which turns
        /// down whatever the worker reaches meanwhile.
        var offeredFromMemory: Set<String> = []
    }

    /// A tile the draw pass drew out of memory, waiting to be offered.
    private struct MemoryOffer: Sendable {
        let key: String
        let z: Int
        let x: Int
        let y: Int
    }

    /// The tiles waiting, and the one worker offering them, which is `nil`
    /// once the queue is empty.
    private struct MemoryOffers {
        var queue: [MemoryOffer] = []
        var worker: Task<Void, Never>?
    }

    private struct PersistenceClaim {
        let hikeID: UUID
        let isNewKey: Bool
    }

    /// What a claim on a tile would come to, as the state lock answers it
    /// before anything slower is asked.
    private enum Prospect {
        case refused
        /// The hike has it already, so a claim only re-promotes its bytes.
        case known
        /// It would be new to the hike, which is under its cap.
        case new
    }

    private let state = Mutex<ActiveHike?>(nil)
    private let memoryOffers = Mutex(MemoryOffers())

    /// Wakes whoever is waiting to hear that a tile has been claimed. A
    /// reader that finishes drops out of its own accord.
    private let pendingKeyWakeups = EventFeed<Void>()

    /// Where claimed tiles are promoted from browsing storage to durable
    /// storage. Injectable for the same reason ``TileCache``'s `storageRoot`
    /// is: a test gets a store with its own directories and its own single
    /// active hike, instead of sharing the process's one of each.
    private let tileCache: TileCache

    init(tileCache: TileCache = .shared) {
        self.tileCache = tileCache
    }

    /// Makes `hikeID` the active auto-save target. Replaces any previously
    /// active hike.
    ///
    /// **Test seam.** No production path calls this, and none should: it
    /// builds the corridor synchronously on the caller's thread, which is the
    /// work the two-phase ``beginActiveHike(id:knownKeys:acceptsNewClaims:)``
    /// / ``updateCorridor(_:for:)`` split exists to keep off the main actor —
    /// see `AutoSaveController.activate(_:)`. It survives because a test
    /// that only needs a store pointed at a route should not have to
    /// reproduce that sequence.
    func setActiveHike(
        id: UUID,
        route: [CLLocationCoordinate2D],
        knownKeys: Set<String>,
        acceptsNewClaims: Bool = true
    ) {
        let corridor = TileCorridor(route: route, bufferMeters: Self.corridorBufferMeters)
        beginActiveHike(
            id: id,
            knownKeys: knownKeys,
            acceptsNewClaims: acceptsNewClaims
        )
        updateCorridor(corridor, for: id)
    }

    /// Installs the inexpensive ownership state immediately while the route
    /// corridor is prepared off-main. The empty corridor rejects every tile,
    /// so no claim can be attached to the hike before its real bounds arrive.
    func beginActiveHike(
        id: UUID,
        knownKeys: Set<String>,
        acceptsNewClaims: Bool = true
    ) {
        state.withLock { activeLock in
            activeLock = ActiveHike(
                id: id,
                corridor: TileCorridor(route: [], bufferMeters: 0),
                acceptsNewClaims: acceptsNewClaims,
                knownKeys: knownKeys,
                pendingKeys: []
            )
        }
    }

    /// Applies a prepared corridor only if the same hike is still active.
    func updateCorridor(_ corridor: TileCorridor, for hikeID: UUID) {
        state.withLock { state in
            guard var hike = state, hike.id == hikeID else { return }
            hike.corridor = corridor
            state = hike
        }
    }

    /// Stops auto-saving — no active hike means `considerPersisting` is a no-op.
    func clearActiveHike() {
        state.withLock { $0 = nil }
    }

    func isCapReached(for hikeID: UUID) -> Bool {
        state.withLock { state in
            guard let state, state.id == hikeID else { return false }
            return state.knownKeys.count >= Self.tileCap
        }
    }

    /// Called after a tile has already been resolved for on-screen display
    /// (memory/disk/network hit alike). No-ops unless a hike is active, is
    /// still accepting claims, and the tile falls in its corridor and in no
    /// downloaded country; a key the hike doesn't already know also has to be
    /// under the cap. Otherwise the cached tile is moved into durable
    /// storage, bytes unchanged.
    func considerPersisting(key: String, z: Int, x: Int, y: Int) {
        assertOffMainThread("considerPersisting moves a file on disk — call it off the main thread")
        // Asked before the claim, so a tile a country holds is never one the
        // hike was told it had, and only of a tile that would be new to it:
        // a map nobody is saving, a tile the hike has already and a hike at
        // its cap cost one lock and no outline or archive.
        switch prospect(forKey: key, z: z, x: x, y: y) {
        case .refused: return
        case .known: break
        case .new: guard !tileCache.isHeldByDownloadedCountry(key) else { return }
        }
        // Claim the tile up front so two threads drawing it at once don't both
        // try to move it; `releaseClaim` undoes that if the bytes never land.
        let claim = state.withLock { state -> PersistenceClaim? in
            guard var hike = state, hike.acceptsNewClaims else { return nil }
            let isNewKey = !hike.knownKeys.contains(key)
            guard
                !isNewKey || hike.knownKeys.count < Self.tileCap,
                hike.corridor.overlaps(z: z, x: x, y: y)
            else { return nil }
            if isNewKey {
                hike.knownKeys.insert(key)
                hike.pendingKeys.insert(key)
            }
            state = hike
            return PersistenceClaim(hikeID: hike.id, isNewKey: isNewKey)
        }
        guard let claim else { return }

        // A claim no bytes back is worse than no claim: it counts against the
        // cap, is reported as saved, and — being "known" — is never
        // reconsidered, so the tile stays missing offline with nothing retrying
        // it. The move fails when there's no cached copy left to move.
        guard tileCache.promoteCachedTile(forKey: key) else {
            if claim.isNewKey {
                releaseClaim(on: key, by: claim.hikeID)
            }
            return
        }
        // Outside the state lock: this is the tile thread, and nothing a
        // reader does in response belongs inside the lock it needs to claim
        // the next tile.
        if claim.isNewKey {
            pendingKeyWakeups.send(())
        }
        #if DEBUG
        Self.logger.debug("Auto-saved tile \(key, privacy: .public)")
        #endif
    }

    /// Called by the map's draw pass for a tile it found in memory and drew as
    /// it was, which no load offers. A tile drawn before *Auto-Save Tiles*
    /// went on, or before its hike was selected, is still in memory when the
    /// hiker pans back over it; without this it stayed in the purgeable cache
    /// while the hike's screen said it was being saved for.
    ///
    /// The draw pass must not wait on the disk, so this asks only what the
    /// state lock answers — a hike is taking claims, the tile is in its
    /// corridor, under its cap, and neither known to it nor queued from
    /// memory for it before — and queues the tile. `key` is made only once
    /// those pass, so a map nobody is saving costs each drawn tile one lock.
    /// One worker off the draw path hands the queue to
    /// ``considerPersisting(key:z:x:y:)`` a tile at a time, which asks the
    /// rest as it does for a tile a load found.
    func offerTileDrawnFromMemory(z: Int, x: Int, y: Int, key: () -> String) {
        let offer = state.withLock { state -> MemoryOffer? in
            let mayClaim = state.map { hike in
                hike.acceptsNewClaims
                    && hike.knownKeys.count < Self.tileCap
                    && hike.corridor.overlaps(z: z, x: x, y: y)
            }
            guard mayClaim == true else { return nil }
            let tileKey = key()
            // In place, through the optional: a binding of the hike would
            // hold a second reference to its sets and copy one to insert.
            guard state.map({ !$0.knownKeys.contains(tileKey) }) == true,
                  state?.offeredFromMemory.insert(tileKey).inserted == true
            else { return nil }
            return MemoryOffer(key: tileKey, z: z, x: x, y: y)
        }
        guard let offer else { return }
        memoryOffers.withLock { offers in
            offers.queue.append(offer)
            guard offers.worker == nil else { return }
            offers.worker = Task(priority: .utility) { [weak self] in
                await self?.offerQueuedTiles()
            }
        }
    }

    /// The worker behind ``offerTileDrawnFromMemory(z:x:y:key:)``: one at a
    /// time, so a screenful of tiles queued in one pass is a few file moves
    /// in a row rather than a task each on the cooperative pool.
    @concurrent
    private func offerQueuedTiles() async {
        var batch = nextMemoryOffers()
        while !batch.isEmpty {
            for offer in batch {
                considerPersisting(key: offer.key, z: offer.z, x: offer.x, y: offer.y)
            }
            batch = nextMemoryOffers()
        }
    }

    /// What is queued, taken in one go: empty, with the worker gone in the
    /// same lock, once nothing is.
    private func nextMemoryOffers() -> [MemoryOffer] {
        memoryOffers.withLock { offers in
            if offers.queue.isEmpty { offers.worker = nil }
            let batch = offers.queue
            offers.queue.removeAll()
            return batch
        }
    }

    /// Waits until every tile the draw pass queued from memory has been
    /// offered. A test seam, waiting on the worker itself rather than on a
    /// duration.
    func waitForMemoryOffers() async {
        while let worker = memoryOffers.withLock({ $0.worker }) {
            await worker.value
        }
    }

    /// Whether a tile could be claimed at all — a hike is active, taking
    /// claims, the tile falls in its corridor, and a key the hike does not
    /// know is under its cap — and whether it would be new. The claim itself
    /// asks again under its own lock, where the answer is acted on.
    private func prospect(forKey key: String, z: Int, x: Int, y: Int) -> Prospect {
        state.withLock { state in
            guard let hike = state, hike.acceptsNewClaims, hike.corridor.overlaps(z: z, x: x, y: y) else {
                return .refused
            }
            if hike.knownKeys.contains(key) { return .known }
            return hike.knownKeys.count < Self.tileCap ? .new : .refused
        }
    }

    /// A signal each time a tile is newly claimed for the active hike and its
    /// bytes are durably on disk — that is, each time there is something for
    /// ``AutoSaveController`` to fold into the hike's manifest.
    ///
    /// The controller used to poll for this every two seconds for the app's
    /// whole foreground lifetime, whether or not a hike was even selected.
    /// Waiting on this instead means it wakes when tiles are actually being
    /// saved and not otherwise.
    ///
    /// `bufferingNewest(1)`: the payload is "there is work", not "here is a
    /// key", so a screenful of tiles arriving in one draw pass has to collapse
    /// into one wake-up rather than one per tile.
    ///
    /// Each call is a stream of its own, so a drain that ends leaves every
    /// other reader, and the next drain, hearing the claims after it.
    func pendingKeySignals() -> AsyncStream<Void> {
        pendingKeyWakeups.events(bufferingPolicy: .bufferingNewest(1))
    }

    /// How many consumers are waiting on ``pendingKeySignals()`` right now.
    ///
    /// **Test seam**, and the only trace a finished drain leaves: a stream
    /// that ends takes itself out of the feed, so a controller whose drain
    /// task really did end is one this no longer counts. A drain nothing
    /// cancels stays suspended on its iterator for the life of the store and
    /// keeps being counted, which is what `AutoSaveTaskLifecycleTests` reads
    /// instead of waiting out a duration.
    var pendingSignalObserverCount: Int {
        pendingKeyWakeups.readerCount
    }

    /// Gives back a claim taken by `considerPersisting` whose tile never made it
    /// to disk. Scoped to the hike that took it, so a selection change mid-write
    /// doesn't punch a hole in the new hike's manifest.
    private func releaseClaim(on key: String, by hikeID: UUID) {
        state.withLock { state in
            guard var hike = state, hike.id == hikeID else { return }
            hike.knownKeys.remove(key)
            hike.pendingKeys.remove(key)
            state = hike
        }
    }

    /// Main-actor bookkeeping hook: returns and clears the keys persisted for
    /// `hikeID` since the last drain, so the caller can merge them into the
    /// hike's SwiftData manifest.
    func drainPendingKeys(for hikeID: UUID) -> Set<String> {
        state.withLock { state -> Set<String> in
            guard var hike = state, hike.id == hikeID else { return [] }
            let drained = hike.pendingKeys
            hike.pendingKeys.removeAll()
            state = hike
            return drained
        }
    }

    /// Stops new claims and returns the pending ownership snapshot in the same
    /// lock acquisition. The keys remain pending until SwiftData confirms that
    /// their manifest update was saved.
    func suspendAndSnapshotPendingKeys(for hikeID: UUID) -> Set<String> {
        state.withLock { state -> Set<String> in
            guard var hike = state, hike.id == hikeID else { return [] }
            hike.acceptsNewClaims = false
            state = hike
            return hike.pendingKeys
        }
    }

    /// Removes only the snapshot successfully committed to SwiftData. Claims
    /// added after a normal foreground snapshot remain pending for a later pass.
    func acknowledgePendingKeys(_ keys: Set<String>, for hikeID: UUID) {
        state.withLock { state in
            guard var hike = state, hike.id == hikeID else { return }
            hike.pendingKeys.subtract(keys)
            state = hike
        }
    }

    func resumePersisting(for hikeID: UUID) {
        state.withLock { state in
            guard var hike = state, hike.id == hikeID else { return }
            hike.acceptsNewClaims = true
            hike.offeredFromMemory.removeAll()
            state = hike
        }
    }
}
