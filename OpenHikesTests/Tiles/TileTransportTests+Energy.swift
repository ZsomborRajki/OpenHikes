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
import MapKit
@testable import OpenHikes
import Testing

extension TileTransportTests {

    /// The asymmetry the whole policy exists for, and the reason there is no
    /// setting in front of it. A walker on cellular is looking at the map
    /// *now*, so the tile under their thumb still loads; what stops is the
    /// bulk download that would have pulled a region they have not asked for
    /// over a metered radio.
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

    /// Metered is a condition, not a mode: nothing latches it and nothing has
    /// to be reset. Walking back into Wi-Fi range is the whole of what it
    /// takes for the app to start reading ahead again, which is what makes a
    /// hands-free app possible without a switch to remember to flip back.
    @Test("leaving cellular restores prefetching with no relaunch")
    func prefetchingResumesOffCellular() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        StubTileProtocol.alwaysRespond(with: .tile())
        stub.cache.setNetworkConditions(
            TileNetworkConditions(isOnline: true, isExpensive: true)
        )

        #expect(await stub.cache.saveTileDurably(forKey: key, url: url()) == false)
        #expect(StubTileProtocol.requestCount == 0)

        stub.cache.setNetworkConditions(TileNetworkConditions(isOnline: true))
        #expect(await stub.cache.saveTileDurably(forKey: key, url: url()))
        #expect(StubTileProtocol.requestCount == 1)
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

    /// Suppression is not a server failure. The overlay preserves that fact so
    /// the renderer does not escalate its retry backoff while Low Data Mode is
    /// doing exactly what the user asked it to do.
    @Test("Low Data Mode suppression is not reported as a failed load")
    func lowDataModeSuppressionIsNotAFailure() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        stub.cache.setNetworkConditions(
            TileNetworkConditions(isOnline: true, isConstrained: true)
        )
        let overlay = TileOverlay(
            providerID: "osm",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: stub.cache,
            autoSaveStore: stub.store
        )
        let path = MKTileOverlayPath(x: 9500, y: 14_600, z: 15, contentScaleFactor: 2)

        let disposition = await offMainEnergy { await overlay.cacheTile(at: path) }

        #expect(disposition == .suppressed)
        #expect(StubTileProtocol.requestCount == 0)
    }

    /// Leaving Low Data Mode is just as much an interactive-fetch transition
    /// as reconnecting. Renderers must clear any older genuine failures and
    /// redraw immediately instead of waiting for their existing backoff.
    @Test("leaving Low Data Mode notifies renderers to retry")
    func leavingLowDataModeNotifiesObservers() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        stub.cache.setNetworkConditions(
            TileNetworkConditions(isOnline: true, isConstrained: true)
        )

        final class Listener: TileCacheObserver, @unchecked Sendable {
            var unblocked = false

            func tileCacheDidUnblockInteractiveFetches() { unblocked = true }
        }

        let listener = Listener()
        stub.cache.addObserver(listener)
        stub.cache.setNetworkConditions(TileNetworkConditions(isOnline: true))

        await settleDelegateHop(until: "Low Data Mode exit to reach the renderer") {
            listener.unblocked
        }
        #expect(listener.unblocked)
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

/// Runs the overlay's async path away from the main actor, where its cache and
/// auto-save file work is required to execute.
@concurrent
private func offMainEnergy<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
    await work()
}
