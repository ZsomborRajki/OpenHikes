//
//  TileTransportTests+Deletion.swift
//  OpenHikesTests
//
//  What a deletion has to beat: a fetch that is already on the wire.
//
//  An extension of `TileTransportTests` rather than a suite of its own,
//  because `StubTileProtocol`'s response script is process-wide and the parent
//  suite is `.serialized` for exactly that reason — a second top-level suite
//  scripting the same stub would run alongside it and read the other's replies.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

extension TileTransportTests {

    /// The other half of that guarantee, and the reason the per-tile deletion
    /// table can't simply be emptied when it gets big.
    ///
    /// Every deleted tile used to add an entry that was never removed, so a
    /// session that deletes a few covered hikes grew the table for the rest of
    /// the process's life. It is compacted now — but a token carries the
    /// version it read, and a missing entry reads back as 0, so clearing the
    /// table on its own would make every stale token compare equal again and
    /// let a fetch that was already invalidated write its tile after all.
    /// Compaction takes the epoch with it for exactly that reason, and this is
    /// the test that says so: the fetch below is invalidated *and then*
    /// compacted past, and must still come back with nothing.
    @Test("compacting the deletion table can't revive an invalidated fetch")
    func compactionCannotRevalidateAnInFlightFetch() async {
        let keyLimit = 4
        let stub = StubbedTileCache(mutationKeyLimit: keyLimit)
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        // Gated rather than delayed. The deletions below have to happen while
        // the response is in flight, and a fixed delay gives them a fixed
        // number of milliseconds to do it in — a window a loaded machine can
        // close.
        StubTileProtocol.holdResponses()

        let cache = stub.cache
        let deleted = key
        let load = Task {
            await cache.loadTile(forKey: deleted, url: url())
        }
        await StubTileProtocol.waitForRequest()

        await offMain {
            cache.removeTiles(forKeys: [deleted])
            // Enough further deletions to push the table past its limit, so
            // the entry that invalidated the fetch above is gone by the time
            // the response lands.
            cache.removeTiles(
                forKeys: (0...keyLimit).map { index in "osm/14/\(index)/1@2.0" }
            )
        }
        let deletedName = cache.diskName(for: deleted)
        #expect(
            cache.mutationVersions.withLock { versions in versions.names[deletedName] } == nil,
            "the fixture only means anything if the tile's own entry was really compacted away"
        )
        StubTileProtocol.releaseResponses()

        let image = await load.value
        #expect(image == nil)
        #expect(!stub.isBrowsed(deleted), "a compacted deletion is still a deletion")
        #expect(!stub.isSaved(deleted))
        #expect(cache.memoryImage(forKey: deleted) == nil)
    }

    /// And the growth itself: deleting past the limit leaves a bounded table
    /// rather than one entry per tile ever deleted.
    @Test("the per-tile deletion table stays bounded")
    func mutationVersionTableIsBounded() async {
        let keyLimit = 8
        let sandbox = TileSandbox(mutationKeyLimit: keyLimit)
        let cache = sandbox.cache

        await offMain {
            cache.removeTiles(
                forKeys: (0..<(keyLimit * 10)).map { index in "osm/14/\(index)/1@2.0" }
            )
        }

        let (global, held) = cache.mutationVersions.withLock { versions in
            (versions.global, versions.names.count)
        }
        #expect(held <= keyLimit)
        #expect(global > 0, "compaction has to take the epoch with it")
    }
}
