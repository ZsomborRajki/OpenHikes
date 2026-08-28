//
//  TileInvalidationTests.swift
//  OpenHikesTests
//
//  Which in-flight fetches a deletion is allowed to throw away.
//
//  `TileCache` hands every fetch a token before it awaits the network and
//  re-checks it before filing the bytes, so a response that lands after the
//  tile was deleted cannot put it back. That is the integrity half, and it is
//  not negotiable. The other half is precision: the three paths that delete
//  tile *files* one at a time — a cache trim, a durable reclaim, and the
//  launch-time quota sweep — used to bump the global epoch per file, which
//  invalidated every unrelated in-flight fetch once per deleted tile. Trimming
//  five hundred tiles did that five hundred times, and each one is a correct
//  response discarded and asked for again, on whatever radio the walker is
//  paying for.
//
//  They invalidate the deleted tile's own row now, keyed by the file name that
//  *is* the tile's storage identity. Every test below pins one of the two
//  halves; both have to hold at once, and the interesting failure is a change
//  that buys precision by giving up integrity.
//
//  Serialized because `StubTileProtocol`'s response script is process-wide,
//  for the same reason `TileTransportTests` is.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile invalidation", .serialized)
struct TileInvalidationTests {
    nonisolated private static let osm = TileProvider.openStreetMap.id
    nonisolated private static let stadia = TileProvider.stadiaOutdoors.id

    /// Stadia's real ceiling divided by this leaves room for three fixture
    /// tiles, so eight of them is comfortably over it.
    nonisolated private static var scaleForThreeTiles: Double {
        Double(TileStore.tileByteCount * 3) / Double(TileProvider.stadiaDurableByteLimit)
    }

    nonisolated private static func osmKey(_ index: Int) -> String {
        "\(osm)/14/\(index)/5000@2.0"
    }

    nonisolated private static func stadiaKey(_ index: Int) -> String {
        "\(stadia)/14/\(index)/5000@2.0"
    }

    private func url() -> URL {
        guard let url = URL(string: "https://tiles.example.invalid/14/99/5000.png") else {
            preconditionFailure("Invalid test URL")
        }
        return url
    }

    /// Starts a fetch and returns once its request is genuinely on the wire
    /// and parked, so what follows races a real in-flight response rather than
    /// a hoped-for one.
    private func heldFetch(of key: String, from cache: TileCache) async -> Task<TileImage?, Never> {
        StubTileProtocol.alwaysRespond(with: .tile())
        StubTileProtocol.holdResponses()
        let load = Task { await cache.loadTile(forKey: key, url: url()) }
        await StubTileProtocol.waitForRequest()
        return load
    }

    // MARK: Trimming the browsing cache

    /// The saving. A trim runs at launch while the first draw pass is already
    /// fetching, and the tiles it takes have nothing to do with the ones being
    /// asked for — so those bytes have to survive it.
    @Test("trimming unrelated tiles keeps an in-flight fetch's bytes")
    func trimKeepsAnUnrelatedInFlightFetch() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let cache = stub.cache

        let residue = (0..<3).map { Self.osmKey($0) }
        for key in residue { try stub.sandbox.browse(key: key) }

        let fetched = Self.osmKey(9)
        let load = await heldFetch(of: fetched, from: cache)

        let freed = await offMain { cache.trimCache(claimedBy: [], limit: 1) }
        #expect(freed > 0, "the fixture only means anything if the trim really deleted something")
        for key in residue {
            #expect(!stub.isBrowsed(key), "and took every unclaimed tile it found")
        }

        StubTileProtocol.releaseResponses()
        let image = await load.value

        #expect(image != nil, "an unrelated deletion must not discard a correct response")
        #expect(stub.isBrowsed(fetched), "and the bytes are filed rather than paid for twice")
        #expect(cache.memoryImage(forKey: fetched) != nil)
    }

    /// The integrity invariant, unchanged: a trim that takes the very tile a
    /// fetch is in flight for still stops that fetch writing it back.
    ///
    /// The file has to appear *after* the request is on the wire, because the
    /// two conditions are otherwise mutually exclusive — `loadTile` only
    /// reaches the network for a tile that is not on disk, and a trim only
    /// deletes tiles that are. That is the same observation `trimCache`'s own
    /// comment records when it says the safety there "was already arithmetic";
    /// the lock is what makes it an invariant, and this holds it to that.
    @Test("trimming the tile a fetch is in flight for still invalidates it")
    func trimStillInvalidatesTheFetchForTheTileItDeleted() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let cache = stub.cache

        let fetched = Self.osmKey(0)
        let load = await heldFetch(of: fetched, from: cache)
        try stub.sandbox.browse(key: fetched)

        let freed = await offMain { cache.trimCache(claimedBy: [], limit: 1) }
        #expect(freed > 0, "the trim has to have taken this tile for the race to exist")
        #expect(!stub.isBrowsed(fetched))

        StubTileProtocol.releaseResponses()
        let image = await load.value

        #expect(image == nil, "a fetch whose tile was deleted must not report success")
        #expect(!stub.isBrowsed(fetched), "and must not put the deleted tile back")
        #expect(!stub.isSaved(fetched))
        #expect(cache.memoryImage(forKey: fetched) == nil)
    }

    // MARK: Reclaiming durable coverage

    /// A reclaim runs behind a confirmation while the map is still on screen —
    /// the deletion path most certain to overlap with fetching.
    @Test("reclaiming unrelated durable tiles keeps an in-flight fetch's bytes")
    func reclaimKeepsAnUnrelatedInFlightFetch() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let cache = stub.cache

        let residue = (0..<3).map { Self.osmKey($0) }
        for key in residue { try stub.sandbox.save(key: key) }

        let fetched = Self.osmKey(9)
        let load = await heldFetch(of: fetched, from: cache)

        let providerID = Self.osm
        let freed = await offMain {
            cache.reclaimDurableBytes(
                forProviderID: providerID,
                protecting: [],
                byteCount: TileStore.tileByteCount * 3
            )
        }
        #expect(freed > 0, "the fixture only means anything if the reclaim deleted something")

        StubTileProtocol.releaseResponses()
        let image = await load.value

        #expect(image != nil, "an unrelated deletion must not discard a correct response")
        #expect(stub.isBrowsed(fetched))
    }

    /// And the same integrity invariant on that path. The tile appears in the
    /// durable tier rather than the browsing one, since that is the only tier
    /// a reclaim reaches — one file name, either way, which is what the
    /// version row is keyed by.
    @Test("reclaiming the tile a fetch is in flight for still invalidates it")
    func reclaimStillInvalidatesTheFetchForTheTileItDeleted() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let cache = stub.cache

        let fetched = Self.osmKey(0)
        let load = await heldFetch(of: fetched, from: cache)
        try stub.sandbox.save(key: fetched)

        let providerID = Self.osm
        let freed = await offMain {
            cache.reclaimDurableBytes(
                forProviderID: providerID,
                protecting: [],
                byteCount: TileStore.tileByteCount
            )
        }
        #expect(freed > 0, "the reclaim has to have taken this tile for the race to exist")

        StubTileProtocol.releaseResponses()
        let image = await load.value

        #expect(image == nil, "a fetch whose tile was deleted must not report success")
        #expect(!stub.isBrowsed(fetched), "and must not put the deleted tile back")
        #expect(!stub.isSaved(fetched))
    }

    // MARK: Launch-time quota enforcement

    /// The third per-file loop. It runs at launch, beside the first draw
    /// pass's fetches, and trims a *capped* provider's oldest coverage — which
    /// says nothing at all about an uncapped provider's tile being fetched at
    /// the same moment.
    @Test("launch quota enforcement keeps an unrelated in-flight fetch's bytes")
    func launchEnforcementKeepsAnUnrelatedInFlightFetch() async throws {
        StubTileProtocol.reset()
        defer { StubTileProtocol.reset() }
        // Built by hand rather than through `StubbedTileCache`, which has no
        // way to shrink the licensed ceiling this test has to exceed.
        let sandbox = TileSandbox(
            sessionConfiguration: StubTileProtocol.sessionConfiguration(),
            durableByteLimitScale: Self.scaleForThreeTiles
        )
        let cache = sandbox.cache

        for index in 0..<8 {
            let key = Self.stadiaKey(index)
            try sandbox.save(key: key)
            try sandbox.age(key: key, byDays: Double(8 - index))
        }

        let fetched = Self.osmKey(9)
        let load = await heldFetch(of: fetched, from: cache)

        let freed = await offMain { cache.enforceDurableByteLimits() }
        #expect(freed > 0, "the store has to be over the ceiling for anything to be deleted")
        #expect(!sandbox.isSaved(Self.stadiaKey(0)), "and the oldest coverage is what goes")

        StubTileProtocol.releaseResponses()
        let image = await load.value

        #expect(image != nil, "a capped provider's sweep says nothing about an OSM tile")
        #expect(sandbox.isBrowsed(fetched))
    }
}

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
