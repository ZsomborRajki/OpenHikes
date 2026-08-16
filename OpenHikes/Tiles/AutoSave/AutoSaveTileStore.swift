//
//  AutoSaveTileStore.swift
//  OpenHikes
//
//  Passively persists tiles for the one hike currently being auto-saved, as a
//  side effect of tiles MapKit already fetched to draw on screen — no bulk
//  enumeration, no extra network requests. This is how providers like OSM
//  (which disallow automated bulk downloading) save anything at all, and it
//  doubles as a gap-filler for bulk-download-capable providers: any tile the
//  bulk pass missed still gets saved the moment it's actually browsed.
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
    }

    private struct PersistenceClaim {
        let hikeID: UUID
        let isNewKey: Bool
    }

    private let state = Mutex<ActiveHike?>(nil)

    /// Consumers waiting to hear that a tile has been claimed, keyed so a
    /// finished one drops out of its own accord.
    private let pendingObservers = Mutex([UUID: AsyncStream<Void>.Continuation]())

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
    /// see ``AutoSaveController/activate(hike:)``. It survives because a test
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
    /// still accepting claims, and the tile falls in its corridor; a key the
    /// hike doesn't already know also has to be under the cap. Otherwise the
    /// cached tile is moved into durable storage, bytes unchanged.
    func considerPersisting(key: String, z: Int, x: Int, y: Int) {
        assertOffMainThread("considerPersisting moves a file on disk — call it off the main thread")
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
        if claim.isNewKey {
            signalPendingKeys()
        }
        #if DEBUG
        Self.logger.debug("Auto-saved tile \(key, privacy: .public)")
        #endif
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
    func pendingKeySignals() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            self?.pendingObservers.withLock { observers in observers[id] = nil }
        }
        pendingObservers.withLock { observers in observers[id] = continuation }
        return stream
    }

    /// Deliberately outside the state lock: this is called from the tile
    /// thread, and nothing a consumer does in response belongs inside the lock
    /// that the tile thread needs to claim the next tile.
    private func signalPendingKeys() {
        let observers = pendingObservers.withLock { observers in
            Array(observers.values)
        }
        for continuation in observers {
            continuation.yield()
        }
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
            state = hike
        }
    }
}
