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

import Foundation

nonisolated extension TileCache {

    /// Above this many per-key entries the table is compacted. Sized so an
    /// ordinary session never reaches it: the auto-save cap is 3,000 tiles a
    /// hike and the bulk-download budget 4,000, so deleting a fully-covered
    /// hike lands well inside one window, and it takes a session that deletes
    /// several of them to compact even once.
    static let mutationKeyVersionLimit = 16_384

    struct MutationVersions {
        var global: UInt64 = 0
        var keys: [String: UInt64] = [:]
        /// Injectable for the same reason `trimCache(claimedBy:limit:)`'s
        /// limit is: so a test can drive compaction with a handful of keys
        /// instead of sixteen thousand file deletions.
        let keyLimit: Int

        init(keyLimit: Int = TileCache.mutationKeyVersionLimit) {
            self.keyLimit = keyLimit
        }

        /// Invalidates every token outstanding for `key`.
        ///
        /// Call inside the same lock acquisition as the deletion itself: that
        /// is what makes "bump then delete" atomic against a fetch's "check
        /// then write", and therefore what stops a late response from putting
        /// a deleted tile back.
        mutating func invalidate(_ key: String) {
            keys[key, default: 0] &+= 1
            compactIfNeeded()
        }

        /// Invalidates every token outstanding for every key.
        ///
        /// Per-key entries are dropped rather than kept, because the epoch
        /// already covers them — see ``compactIfNeeded()``.
        mutating func invalidateAll() {
            global &+= 1
            keys.removeAll()
        }

        /// Bounds the table, which otherwise gains an entry per deleted key
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
            guard keys.count > keyLimit else { return }
            invalidateAll()
        }
    }
}
