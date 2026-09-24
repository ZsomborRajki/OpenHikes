//
//  TileCache+MutationVersions.swift
//  OpenHikes
//
//  Orders a tile's disk and memory writes against its deletion.
//
//  A fetch takes a token before it awaits the network and re-checks it before
//  it files the bytes, so a response that lands after the user deleted the
//  hike that wanted it cannot put the tile back. The versions the token is
//  read from live here, along with the bookkeeping that keeps them from
//  growing for the lifetime of the process.
//
//  The table is keyed by the tile's *disk name* rather than by its cache key,
//  which is what lets a path that deletes files — a trim, a durable reclaim —
//  invalidate the one tile it removed instead of the whole epoch. See
//  ``TileCache/MutationVersions/names``.
//

import Foundation

nonisolated extension TileCache {

    /// Above this many per-tile entries the table is compacted. Sized so an
    /// ordinary session never reaches it: the auto-save cap is 3,000 tiles a
    /// hike and the bulk-download budget 4,000, so deleting a fully-covered
    /// hike lands well inside one window, and it takes a session that deletes
    /// several of them to compact even once.
    static let mutationKeyVersionLimit = 16_384

    struct MutationVersions {
        var global: UInt64 = 0

        /// Per-tile deletion counts, keyed by the tile's **disk name** —
        /// what ``TileCache/diskName(for:)`` produces — rather than by its
        /// cache key.
        ///
        /// The disk name *is* the storage identity: ``TileCache/filePaths(forKey:)``
        /// derives both tiers' URLs from it and from nothing else, so two keys
        /// that flatten to one name already address one pair of files. Keying
        /// by name is therefore exactly as precise as the storage these
        /// versions order writes against — not a lossy approximation of the
        /// key — and it cannot under-invalidate, because deleting a file bumps
        /// every key that could have written it. Real keys don't collide
        /// anyway: `providerID/z/x/y@scale` has four trailing separator-free
        /// fields, so the provider id is recoverable and the mapping is
        /// injective over the catalog.
        ///
        /// Keyed this way because the deleting paths have names rather than
        /// keys — ``TileCache/trimCache(claimedBy:limit:)`` and
        /// ``TileCache/reclaimDurableBytes(forProviderID:protecting:byteCount:)``
        /// enumerate *files*, and the flattening is one-way (`/` and `@` both
        /// become `_`), so reversing it would need a stored key or a reverse
        /// map. Going this direction needs neither: every reader of a token
        /// already holds the key and can flatten it.
        var names: [String: UInt64] = [:]

        /// Injectable for the same reason `trimCache(claimedBy:limit:)`'s
        /// limit is: so a test can drive compaction with a handful of tiles
        /// instead of sixteen thousand file deletions.
        ///
        /// Still spelled "key" because the ceiling reaches this type through
        /// `TileCache.init(mutationKeyLimit:)`, which names it that.
        let keyLimit: Int

        init(keyLimit: Int = TileCache.mutationKeyVersionLimit) {
            self.keyLimit = keyLimit
        }

        /// Invalidates every token outstanding for one tile: `name` is a disk
        /// name — ``TileCache/diskName(for:)`` — and not a cache key.
        ///
        /// Call inside the same lock acquisition as the deletion itself: that
        /// is what makes "bump then delete" atomic against a fetch's "check
        /// then write", and therefore what stops a late response from putting
        /// a deleted tile back.
        mutating func invalidate(_ name: String) {
            names[name, default: 0] &+= 1
            compactIfNeeded()
        }

        /// Invalidates every token outstanding for every tile.
        ///
        /// For the paths that clear a whole directory rather than delete named
        /// files — ``TileCache/removeAllTiles()`` and
        /// ``TileCache/removeTiles(unclaimedBy:)``, which each bump once and
        /// then sweep. There one bump is both cheaper than an entry per file
        /// and no less precise, since nothing is left for a token to be valid
        /// against.
        ///
        /// A loop that deletes one file at a time must use ``invalidate(_:)``
        /// instead. Bumping the epoch per tile makes every in-flight fetch
        /// discard a correct response once per deleted tile — safe, but on a
        /// metered radio it throws away bytes that were already paid for, and
        /// a trim deleting five hundred tiles used to do it five hundred
        /// times.
        ///
        /// Per-tile entries are dropped rather than kept, because the epoch
        /// already covers them — see ``compactIfNeeded()``.
        mutating func invalidateAll() {
            global &+= 1
            names.removeAll()
        }

        /// Bounds the table, which otherwise gains an entry per deleted tile
        /// and never loses one — a deletion-heavy session grows it for the
        /// process's lifetime.
        ///
        /// Clearing it on its own would be a correctness bug rather than a
        /// saving: a token carries the version it read, a missing entry reads
        /// back as 0, and so every stale token from before the clear would
        /// compare equal again and be allowed to write its tile. Bumping the
        /// epoch in the same acquisition invalidates all of them instead,
        /// which errs the safe way — an in-flight fetch discards bytes it
        /// already has and the next draw pass asks for them again.
        private mutating func compactIfNeeded() {
            guard names.count > keyLimit else { return }
            invalidateAll()
        }
    }
}
