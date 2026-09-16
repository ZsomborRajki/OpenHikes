//
//  TileMutationVersionTests.swift
//  OpenHikesTests
//
//  "Tile mutation versions", split out of TileInvalidationTests.swift so that
//  a file declares one @Suite. That file's header still holds the context the
//  two share.
//

import Foundation
@testable import OpenHikes
import Testing

/// The version table on its own, with no cache and no disk around it.
///
/// The suite above says what the deleting paths do with it; these two say what
/// it does, which is where the precision and the compaction hazard each live.
@Suite("Tile mutation versions")
struct TileMutationVersionTests {
    nonisolated private static let deleted = "osm_14_1_5000_2.0"
    nonisolated private static let untouched = "osm_14_2_5000_2.0"

    /// Deleting one tile is not an epoch. A token taken for any other tile has
    /// to still compare equal afterwards, which is the whole difference
    /// between refetching one tile and refetching the screen.
    @Test("invalidating one tile leaves every other tile's token intact")
    func invalidationIsPerTile() {
        var versions = TileCache.MutationVersions()

        versions.invalidate(Self.deleted)

        #expect(versions.global == 0, "a single tile's deletion must not bump the epoch")
        #expect(versions.names[Self.deleted] == 1)
        #expect(versions.names[Self.untouched] == nil, "nor touch another tile's row")
    }

    /// Compaction bounds the table, and it has to take the epoch with it: a
    /// missing row reads back as 0, so clearing alone would make every stale
    /// token compare equal again and let an invalidated fetch write after all.
    @Test("compaction bumps the epoch rather than only clearing the table")
    func compactionTakesTheEpochWithIt() {
        let limit = 2
        var versions = TileCache.MutationVersions(keyLimit: limit)

        for index in 0...limit { versions.invalidate("osm_14_\(index)_5000_2.0") }

        #expect(versions.names.isEmpty, "the table has to actually shrink")
        #expect(versions.global == 1, "or every stale token would be revalidated by the clear")
    }
}
