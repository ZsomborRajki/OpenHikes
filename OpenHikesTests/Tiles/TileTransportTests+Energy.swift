//
//  TileTransportTests+Energy.swift
//  OpenHikesTests
//
//  What the cache refuses to put on the radio, and what it still must not
//  refuse. Drawn through the real ``TileCache`` rather than through
//  ``TileNetworkPolicy`` alone, because the policy being right and the cache
//  actually consulting it are two different claims and only the second one
//  saves a walker any battery.
//
//  An extension of `TileTransportTests` for the reason given in
//  `TileTransportTests+Deletion.swift`: `StubTileProtocol` is process-wide and
//  the parent suite is `.serialized` to keep it that way.
//

import Foundation
@testable import OpenHikes
import Testing

extension TileTransportTests {

    /// The asymmetry the whole policy exists for. A walker on cellular is
    /// looking at the map *now*, so the tile under their thumb still loads;
    /// what stops is the bulk download that would have pulled a region they
    /// have not asked for over a metered radio.
    @Test("on cellular, browsing still fetches but prefetching does not")
    func cellularAllowsBrowsingAndStopsPrefetching() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        stub.cache.setNetworkConditions(
            TileNetworkConditions(isOnline: true, isExpensive: true)
        )

        #expect(await stub.cache.loadTile(forKey: key, url: url()) != nil)
        // A different tile, because promoting one already in the browsing tier
        // is a file move rather than a request — free, and so never something
        // the policy should be asked about.
        let neighbour = "osm/14/2639/6357@2.0"
        #expect(
            await stub.cache.saveTileDurably(
                forKey: neighbour,
                url: url("14/2639/6357.png")
            ) == false
        )
        #expect(StubTileProtocol.requestCount == 1)
    }

    /// Turning the setting off is the walker saying they are on a plan they
    /// care about. At that point even the visible map waits for Wi-Fi.
    @Test("with cellular downloads off, even browsing waits for Wi-Fi")
    func cellularSettingSuppressesBrowsing() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        stub.cache.setNetworkConditions(
            TileNetworkConditions(isOnline: true, isExpensive: true)
        )
        stub.cache.setAllowsCellularDownloads(false)

        #expect(await stub.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(StubTileProtocol.requestCount == 0)

        // …and the setting is not a permanent state: back on Wi-Fi the same
        // tile loads, with no reset or relaunch in between.
        stub.cache.setNetworkConditions(TileNetworkConditions(isOnline: true))
        #expect(await stub.cache.loadTile(forKey: key, url: url()) != nil)
    }

    /// Low Data Mode is the one condition with no override. The user has told
    /// the system to stop speculative traffic system-wide, and a hiking app is
    /// not the exception to that.
    @Test("in Low Data Mode nothing speculative leaves the device")
    func lowDataModeSuppressesEverything() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        stub.cache.setNetworkConditions(
            TileNetworkConditions(isOnline: true, isConstrained: true)
        )

        #expect(await stub.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(await stub.cache.saveTileDurably(forKey: key, url: url()) == false)
        #expect(StubTileProtocol.requestCount == 0)
    }

    /// Low Power Mode is a battery signal, not a data one, so it stops the
    /// prefetch and leaves the map the walker is reading alone.
    @Test("in Low Power Mode the map still draws and the prefetch stops")
    func lowPowerModeStopsPrefetchOnly() async {
        let stub = StubbedTileCache(power: PowerState(isLowPowerModeEnabled: true))
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())

        #expect(await stub.cache.loadTile(forKey: key, url: url()) != nil)
        let neighbour = "osm/14/2639/6357@2.0"
        #expect(
            await stub.cache.saveTileDurably(
                forKey: neighbour,
                url: url("14/2639/6357.png")
            ) == false
        )
        #expect(StubTileProtocol.requestCount == 1)
    }
}
