//
//  TileCache+MemoryTier.swift
//  OpenHikes
//
//  The tier the map actually draws from, and the only one a draw pass may
//  touch: `CachingTileOverlayRenderer.draw` paints what
//  ``TileCache/memoryImage(forKey:referenceDate:)`` returns and nothing else.
//
//  Which makes admission the whole design. An entry here is either a current
//  tile, held until its TTL runs out, or saved coverage admitted knowing it
//  was stale — drawn by the map ahead of its refresh, or kept because no
//  refresh could be made to work — and those are held for a short recheck
//  window instead, so the map has something to draw without the staleness
//  becoming permanent.
//

import Foundation
import os
import Synchronization

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

nonisolated extension TileCache {

    /// Puts a tile in the memory tier, charged at its decoded size.
    ///
    /// The single insertion point on purpose: `setObject(_:forKey:)` without a
    /// cost enters as free, and one call site that forgot would quietly exempt
    /// its tiles from ``memoryByteLimit`` — with no symptom until the app is
    /// killed for memory somewhere else entirely.
    ///
    /// Internal, not private: the fetch-store paths in `TileCache` publish
    /// through here too, and `private` in an extension is file-scoped.
    func cacheInMemory(
        _ image: TileImage,
        storedAt: Date,
        forKey key: String,
        servedStaleAt: Date? = nil
    ) {
        let tile = MemoryTile(image: image, storedAt: storedAt, servedStaleAt: servedStaleAt)
        // swiftlint:disable:next legacy_objc_type
        memory.setObject(tile, forKey: key as NSString, cost: tile.byteCost)
    }

    /// Holds stale saved coverage in the memory tier so the map can draw it,
    /// and calls this when to go and ask for fresh bytes again.
    ///
    /// Short, because the entry it governs is showing the hiker ground that
    /// may have changed, and every expiry is one disk read and at most one
    /// refresh attempt for a tile that is on screen — none while one is
    /// already under way or a failed one is backing off. Long enough that a
    /// map held still over stale coverage is not re-reading it every draw
    /// pass — which is the cost the memory tier exists to remove.
    static let staleCoverageRecheckInterval: TimeInterval = 5 * 60

    /// Fast, synchronous memory-only lookup — safe to call from the render loop.
    ///
    /// Applies the TTL lazily, evicting as it finds one expired. This is the
    /// *only* thing keeping a stale tile off the screen — the disk sweeps
    /// deliberately don't touch this tier — so an expired entry must never be
    /// returned from here, however it got in.
    ///
    /// The exception is an entry admitted *knowing* it was stale: saved
    /// coverage the map draws ahead of its refresh, or keeps once a refresh
    /// was refused or failed, because the hiker's saved map is the only map
    /// there is. Those answer for ``staleCoverageRecheckInterval`` and are
    /// then evicted, which sends the next draw back down to the load path to
    /// read the copy again and try the network again. The TTL is not
    /// consulted for them at all: it is the reason they are here.
    ///
    /// They are also retired early by ``staleCoverageInvalidatedAt``, which
    /// moves whenever interactive fetching is unblocked — the recheck interval
    /// is a ceiling on how long staleness may stand, not a delay to serve out
    /// after the phone has signal again.
    ///
    /// `referenceDate` is defaulted for the same reason it is on
    /// ``removeExpiredTiles(referenceDate:)``: a test can't wait out a
    /// seven-day TTL, and a memory entry's age comes from when it was cached
    /// rather than from a file it could backdate.
    func memoryImage(forKey key: String, referenceDate: Date = Date()) -> TileImage? {
        // swiftlint:disable:next legacy_objc_type
        let cacheKey = key as NSString
        guard let tile = memory.object(forKey: cacheKey) else { return nil }
        let isUsable = if let servedStaleAt = tile.servedStaleAt {
            servedStaleAt > staleCoverageInvalidatedAt.withLock({ $0 })
                && referenceDate.timeIntervalSince(servedStaleAt) < Self.staleCoverageRecheckInterval
        } else {
            !isExpired(tile.storedAt, referenceDate: referenceDate)
        }
        guard isUsable else {
            memory.removeObject(forKey: cacheKey)
            return nil
        }
        return tile.image
    }

    /// Admits stale saved coverage to the memory tier, marked as such, so the
    /// draw pass that asked for it can actually paint it. See
    /// ``MemoryTile/servedStaleAt`` for why both halves of that are required.
    func publishStaleCoverage(
        _ image: TileImage,
        forKey key: String,
        token: MutationToken
    ) -> Bool {
        let name = diskName(for: key)
        return mutationVersions.withLock { versions in
            guard token == Self.mutationToken(forName: name, in: versions) else { return false }
            cacheInMemory(image, storedAt: Date(), forKey: key, servedStaleAt: Date())
            return true
        }
    }

    func publishDiskTile(
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
}
