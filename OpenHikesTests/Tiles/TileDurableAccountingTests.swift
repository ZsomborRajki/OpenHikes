//
//  TileDurableAccountingTests.swift
//  OpenHikesTests
//
//  The running total of a capped provider's durable bytes, and the two
//  browse-path mutations that used to happen behind its back.
//
//  `TileDurableQuotaTests` owns the ceiling itself — who is refused and what
//  is reclaimed. This suite owns the arithmetic underneath it: the number
//  `reserveDurableBytes` decides from is maintained incrementally between
//  directory walks, so a mutation that forgets to move it makes every later
//  decision wrong without anything failing at the time.
//
//  Both defects it covers were on the *browse* path, where a durable tile can
//  be deleted (its TTL elapsed while the map was drawing it) and rewritten (a
//  fetch puts the refreshed bytes back in the tier they came from) without any
//  reservation being involved. Neither moved the total, and the two errors
//  cancelled each other exactly often enough to look like nothing was wrong —
//  which is why every assertion here compares the maintained total against a
//  fresh walk of the directory rather than against the other half of the pair.
//
//  `.serialized` for the same reason `TileTransportTests` is: `StubTileProtocol`
//  scripts responses through process-wide state, so two tests scripting it at
//  once would answer each other's requests.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Durable tile accounting", .serialized)
struct TileDurableAccountingTests {
    nonisolated private static let stadia = TileProvider.stadiaOutdoors.id
    nonisolated private static let osm = TileProvider.openStreetMap.id

    /// Shrinks Stadia's ceiling to a byte under two fixture tiles, so a store
    /// holding two is a store with nothing left. A byte under rather than
    /// exactly two because the scale is applied in floating point, and a
    /// ceiling that rounded a byte the *other* way would leave room for the
    /// write these tests need to see go through unreserved.
    private static var scaleForTwoTiles: Double {
        Double(TileStore.tileByteCount * 2 - 1) / Double(TileProvider.stadiaDurableByteLimit)
    }

    private static func key(_ index: Int, provider providerID: String = stadia) -> String {
        "\(providerID)/14/\(7000 + index)/5100@2x"
    }

    private static func url(_ index: Int) -> URL {
        guard let url = URL(string: "https://tiles.example.invalid/14/\(7000 + index)/5100.png") else {
            preconditionFailure("Invalid test URL for tile \(index)")
        }
        return url
    }

    /// A sandbox whose transport is the scripted `URLProtocol` the tile suites
    /// share. `StubbedTileCache` covers the same ground, but it cannot shrink
    /// the durable ceiling, and the refusal case has to reach one.
    private static func stubbedSandbox(durableByteLimitScale: Double = 1) -> TileSandbox {
        StubTileProtocol.reset()
        StubTileProtocol.alwaysRespond(with: .tile())
        return TileSandbox(
            sessionConfiguration: StubTileProtocol.sessionConfiguration(),
            durableByteLimitScale: durableByteLimitScale
        )
    }

    /// The maintained total, read without measuring — `durableSpace` would
    /// paper over a dropped measurement by taking a fresh one, and whether the
    /// measurement survived is half of what these tests are about.
    private static func maintainedBytes(_ cache: TileCache, _ providerID: String = stadia) -> Int64? {
        cache.durableProviderBytes.withLock { $0[providerID] }
    }

    /// What a full walk of the durable directory says the provider holds —
    /// the ground truth every maintained total is checked against.
    private static func measuredBytes(_ cache: TileCache, _ providerID: String = stadia) async -> Int64? {
        await offMain {
            cache.invalidateDurableMeasurements()
            return cache.durableSpace(forProviderID: providerID)?.used
        }
    }

    /// Bytes no image decoder will accept, for the tile that is present and
    /// fresh and still unusable — a truncated download, or a captive portal's
    /// login page saved under a tile's name.
    private static func placeUndecodable(at file: URL, byteCount: Int64) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x7A, count: Int(byteCount)).write(to: file, options: .atomic)
    }

    // MARK: The lazy TTL deletion

    /// The headline for the read side. A durable tile whose seven days ran out
    /// is deleted by the first browse that goes looking for it, and the
    /// provider gets those bytes back there and then — not at the next launch,
    /// which is when `removeExpiredTiles` would otherwise have noticed.
    @Test("an expired durable tile gives its bytes back as it is deleted")
    func expiredDurableTileIsCredited() async throws {
        let sandbox = TileSandbox(reachable: false)
        let expired = Self.key(0)
        try sandbox.place(in: sandbox.savedFile(for: expired), agedByDays: 8)
        try sandbox.save(key: Self.key(1))

        let before = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        #expect(try #require(before).used == TileStore.tileByteCount * 2, "precondition: both tiles counted")

        // Offline, so the browse gets as far as the disk tiers and no
        // further: what the total does here is the deletion's doing alone.
        #expect(await sandbox.cache.loadTile(forKey: expired, url: Self.url(0)) == nil)
        #expect(!sandbox.isSaved(expired), "precondition: the TTL took it")

        #expect(Self.maintainedBytes(sandbox.cache) == TileStore.tileByteCount)
        #expect(await Self.measuredBytes(sandbox.cache) == TileStore.tileByteCount)
    }

    /// The same deletion reached through the promote path, which stats the
    /// durable tier before it decides whether a browsed tile needs saving.
    @Test("a promote that finds an expired durable tile credits it too")
    func promoteCreditsAnExpiredDurableTile() async throws {
        let sandbox = TileSandbox()
        let expired = Self.key(0)
        try sandbox.place(in: sandbox.savedFile(for: expired), agedByDays: 8)
        try sandbox.save(key: Self.key(1))
        _ = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }

        // Nothing in the browsing tier, so this only deletes: there is no
        // cached copy to promote in its place.
        #expect(await offMain { !sandbox.cache.promoteCachedTile(forKey: expired) })

        #expect(Self.maintainedBytes(sandbox.cache) == TileStore.tileByteCount)
        #expect(await Self.measuredBytes(sandbox.cache) == TileStore.tileByteCount)
    }

    /// The other half of the deletion rule, and the reason the tier is a
    /// parameter rather than something the helper works out for itself: an
    /// expiring *browsing* tile spends none of a provider's ceiling, so it
    /// must not move the total — and must not drop the measurement either,
    /// which would make the next reservation walk the directory for nothing.
    @Test("an expired browsing tile leaves the provider total alone")
    func expiredBrowsingTileIsNotCredited() async throws {
        let sandbox = TileSandbox(reachable: false)
        let browsed = Self.key(0)
        try sandbox.place(in: sandbox.browsedFile(for: browsed), agedByDays: 8)
        try sandbox.save(key: Self.key(1))
        _ = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }

        #expect(await sandbox.cache.loadTile(forKey: browsed, url: Self.url(0)) == nil)
        #expect(!sandbox.isBrowsed(browsed), "precondition: the TTL took it")

        #expect(
            Self.maintainedBytes(sandbox.cache) == TileStore.tileByteCount,
            "unchanged, and still measured — a browsing expiry must not cost a directory walk"
        )
    }

    /// An uncapped provider has no total at all, and a deletion on its tiles
    /// must not conjure one.
    @Test("an uncapped provider is not given a total by a deletion")
    func uncappedProviderStaysUnmeasured() async throws {
        let sandbox = TileSandbox(reachable: false)
        let expired = Self.key(0, provider: Self.osm)
        try sandbox.place(in: sandbox.savedFile(for: expired), agedByDays: 8)

        #expect(await sandbox.cache.loadTile(forKey: expired, url: Self.url(0)) == nil)
        #expect(!sandbox.isSaved(expired))
        #expect(Self.maintainedBytes(sandbox.cache, Self.osm) == nil)
    }

    // MARK: The durable re-fetch write

    /// The write side. A tile that was durable is re-fetched into the durable
    /// tier, and those bytes are counted — by the difference they make, since
    /// the file they replace may still be there and already counted.
    ///
    /// Driven through the tile that is present, fresh, and undecodable,
    /// because that is the case where the two halves of this pair cannot
    /// cancel: nothing was deleted, so a total that does not move is a total
    /// that is simply wrong.
    @Test("a re-fetched durable tile is counted by what it changes")
    func refetchedDurableTileIsCounted() async throws {
        let sandbox = Self.stubbedSandbox()
        defer { StubTileProtocol.reset() }
        let key = Self.key(0)
        let placeholderBytes: Int64 = 10
        try Self.placeUndecodable(at: sandbox.savedFile(for: key), byteCount: placeholderBytes)
        try sandbox.save(key: Self.key(1))

        let before = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        #expect(try #require(before).used == TileStore.tileByteCount + placeholderBytes)

        #expect(await sandbox.cache.loadTile(forKey: key, url: Self.url(0)) != nil)
        #expect(sandbox.isSaved(key), "precondition: the refreshed tile went back into the tier it came from")
        #expect(!sandbox.isBrowsed(key))

        #expect(
            Self.maintainedBytes(sandbox.cache) == TileStore.tileByteCount * 2,
            "the replaced file's bytes are released and the new ones counted, not both counted at once"
        )
        #expect(await Self.measuredBytes(sandbox.cache) == TileStore.tileByteCount * 2)
    }

    /// The reason this write is *counted* rather than *reserved*. At the
    /// ceiling a reservation refuses, and a refusal on this path fails the
    /// browse: the walker's map goes blank exactly where their hike's own
    /// offline coverage is, and the tile they had is gone while the manifest
    /// still claims it. Refreshing a tile that is already counted cannot grow
    /// the store, so it must not be able to be turned away.
    @Test("a re-fetched durable tile is never refused at the ceiling")
    func refetchAtTheCeilingIsNotRefused() async throws {
        let sandbox = Self.stubbedSandbox(durableByteLimitScale: Self.scaleForTwoTiles)
        defer { StubTileProtocol.reset() }
        let key = Self.key(0)
        try Self.placeUndecodable(at: sandbox.savedFile(for: key), byteCount: TileStore.tileByteCount)
        try sandbox.save(key: Self.key(1))

        #expect(
            await offMain { sandbox.cache.isDurableLimitReached(forKey: key) },
            "precondition: the provider is at its ceiling before the re-fetch"
        )

        #expect(await sandbox.cache.loadTile(forKey: key, url: Self.url(0)) != nil, "the walker still gets their tile")
        #expect(sandbox.isSaved(key), "and their hike still has it offline")
        #expect(await Self.measuredBytes(sandbox.cache) == TileStore.tileByteCount * 2, "with no more bytes spent")
    }

    // MARK: The adjustment itself

    /// An adjustment is not a measurement. A provider whose tiles have never
    /// been walked must come out of this unmeasured rather than holding a
    /// total made of one tile, which would under-count the store and let the
    /// ceiling be overrun by everything already on disk.
    @Test("an adjustment before any measurement installs nothing")
    func adjustmentDoesNotStandInForAMeasurement() async throws {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.key(0))
        try sandbox.save(key: Self.key(1))

        sandbox.cache.adjustDurableBytes(forProviderID: Self.stadia, by: 5000)
        #expect(Self.maintainedBytes(sandbox.cache) == nil)

        let measured = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }
        #expect(try #require(measured).used == TileStore.tileByteCount * 2, "the walk answers, not the adjustment")
    }

    /// A total is a quantity of bytes, so it has a floor. Subtracting more
    /// than is there — two threads finding the same tile expired, a file that
    /// grew between the measurement and the deletion — leaves zero rather than
    /// a negative ceiling nothing could ever fit under.
    @Test("a total is never driven below zero")
    func adjustmentClampsAtZero() async throws {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.key(0))
        _ = await offMain { sandbox.cache.durableSpace(forProviderID: Self.stadia) }

        sandbox.cache.adjustDurableBytes(forProviderID: Self.stadia, by: -TileStore.tileByteCount * 10)
        #expect(Self.maintainedBytes(sandbox.cache) == 0)
    }
}
