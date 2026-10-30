//
//  TileRendererSavedTileTests.swift
//  OpenHikesTests
//
//  A tile already on disk needs no request, and the renderer made it wait for
//  one anyway. It took a `TileLoadGate` slot before it read the disk, and a
//  slot is held for as long as a server takes to answer — on one bar on a
//  ridge, up to the session's idle timeout. Six slow requests for the tiles
//  around it kept a tile saved for offline use off the screen until one of
//  them ended. Saved coverage past its age waited longest of all: it was
//  refreshed before it was drawn, so after the slot it waited out its own
//  request too. It is drawn first now, and refreshed behind the drawn copy;
//  what that refresh may and may not do is in
//  `TileRendererSavedTileTests+StaleCoverage.swift`.
//
//  Slow is a state here rather than a duration: the stub holds every request
//  open until the test lets it go (see `StubTileProtocol`). Each renderer
//  gets a gate of its own with the app's budgets, because the shared one is
//  live in the host app and filling it would stall whatever is drawing there.
//
//  Serialized because `StubTileProtocol`'s response script is process-wide,
//  for the same reason `TileTransportTests` is.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Tile renderer saved tiles", .serialized, .timeLimit(.minutes(1)))
struct TileRendererSavedTileTests {
    /// Which disk tier a test puts its tile in before asking for it.
    nonisolated enum Placement: Sendable {
        /// Saved for offline use, by a download or by auto-save.
        case saved
        /// Drawn before, and still in the browsing cache.
        case browsed
    }

    static let providerID = "osm_saved_tile_test"

    /// One row of tiles at one zoom, none of them stored until a test puts
    /// one there.
    static func path(_ column: Int) -> MKTileOverlayPath {
        MKTileOverlayPath(x: 8600 + column, y: 5800, z: 14, contentScaleFactor: 2)
    }

    static func key(for path: MKTileOverlayPath) -> String {
        TileCacheKey.namespaced(providerID: providerID, z: path.z, x: path.x, y: path.y)
    }

    /// A day past the seven-day age at which saved coverage is due a refresh.
    static let staleByDays: Double = 8

    /// When the bytes on disk were last written, which is how a test tells a
    /// copy left alone from one replaced: a refreshed tile has the same name
    /// and the same bytes as the stub's fixture it replaced.
    static func modificationDate(of file: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    }

    /// Whether the memory tier holds a current tile for `key`, rather than
    /// a stale copy or nothing. A stale entry answers only for the recheck
    /// interval, so asking past it tells the two apart.
    static func holdsCurrentTile(_ cache: TileCache, forKey key: String) -> Bool {
        let pastRecheck = Date(timeIntervalSinceNow: TileCache.staleCoverageRecheckInterval * 2)
        return cache.memoryImage(forKey: key, referenceDate: pastRecheck) != nil
    }

    func renderer(on stub: StubbedTileCache, gate: TileLoadGate) -> CachingTileOverlayRenderer {
        let overlay = TileOverlay(
            providerID: Self.providerID,
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: stub.cache,
            autoSaveStore: stub.store
        )
        return CachingTileOverlayRenderer(overlay: overlay, gate: gate)
    }

    /// Waits until `condition` holds or five seconds pass. Not a
    /// ``settleDelegateHop(until:sourceLocation:condition:)``, because the
    /// gate is an actor and a settle condition cannot `await`. The caller
    /// still asserts, so a lapsed deadline is reported as the expectation it
    /// was waiting for.
    func settle(untilTrue condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            guard await settlePollTick() else { break }
        }
    }

    /// Asks for one tile that is on no disk per slot the map can take, with
    /// every request held open, and returns the number of slots once each is
    /// held by a request on the wire. With no download running, that is all
    /// of them.
    func fillEverySlot(of gate: TileLoadGate, from renderer: CachingTileOverlayRenderer) async -> Int {
        StubTileProtocol.alwaysRespond(with: .tile())
        StubTileProtocol.holdResponses()
        let slots = await gate.budgets.total
        for column in 0..<slots { renderer.loadTileForTesting(at: Self.path(column)) }
        await settle { await gate.inFlight.total == slots && StubTileProtocol.requestCount == slots }
        #expect(await gate.inFlight.total == slots, "precondition: the loads hold every slot")
        #expect(StubTileProtocol.requestCount == slots, "precondition: each with a request open")
        return slots
    }

    /// Lets the held requests answer, and waits for every load to give its
    /// slot back, so nothing is still writing into the sandbox when it goes.
    func drain(_ gate: TileLoadGate) async {
        StubTileProtocol.releaseResponses()
        await settle { await gate.inFlight.total == 0 }
        #expect(await gate.inFlight.total == 0, "every load ends once its server answers")
    }

    /// The headline. The map draws only what the memory tier holds, so the
    /// tile reaching it is the tile reaching the screen — and it has to get
    /// there while the requests ahead of it are still waiting on the server.
    @Test("a tile on disk is drawn while slow requests hold every slot", arguments: [Placement.saved, .browsed])
    func storedTileSkipsTheQueue(placement: Placement) async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let gate = TileLoadGate()
        let renderer = renderer(on: stub, gate: gate)
        let slots = await fillEverySlot(of: gate, from: renderer)

        let stored = Self.path(slots)
        let key = Self.key(for: stored)
        switch placement {
        case .saved: try stub.sandbox.save(key: key)
        case .browsed: try stub.sandbox.browse(key: key)
        }
        renderer.loadTileForTesting(at: stored)

        await settleDelegateHop(until: "the tile on disk to reach the memory tier the map draws from") {
            stub.cache.memoryImage(forKey: key) != nil
        }
        let state = await gate.testState
        #expect(state.interactiveWaiters == 0, "it never queued behind the requests")
        #expect(state.total == slots, "which still hold every slot")
        #expect(StubTileProtocol.requestCount == slots, "and it asked no server for anything")

        await drain(gate)
    }

    /// Auto-save keeps what the map draws, however the map found it. A tile
    /// drawn from the browsing cache is how OpenStreetMap, which allows no
    /// bulk download, saves anything for a hike at all, so reading it
    /// outside the gate must still offer it.
    @Test("a tile drawn from the browsing cache is still kept for the auto-saved hike")
    func storedTileIsOfferedToAutoSave() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let gate = TileLoadGate()
        let renderer = renderer(on: stub, gate: gate)
        _ = await fillEverySlot(of: gate, from: renderer)

        let route = Fixture.coordinates(Fixture.ridgeRoute)
        let onTrail = MKTileOverlayPath(
            x: SlippyTileMath.tileX(route[2].longitude, z: 14),
            y: SlippyTileMath.tileY(route[2].latitude, z: 14),
            z: 14,
            contentScaleFactor: 2
        )
        let key = Self.key(for: onTrail)
        try stub.sandbox.browse(key: key)
        let hikeID = UUID()
        stub.store.setActiveHike(id: hikeID, route: route, knownKeys: [])
        renderer.loadTileForTesting(at: onTrail)

        await settleDelegateHop(until: "the browsed tile to be kept for the hike") { stub.isSaved(key) }
        #expect(stub.store.drainPendingKeys(for: hikeID) == [key])
        #expect(!stub.isBrowsed(key), "moved out of the cache, not copied")

        await drain(gate)
    }

    /// The other half, and what the gate is for: a tile that may need a
    /// request still waits for a slot, so slow servers never get more of the
    /// map's requests at once than the budget allows.
    @Test("a tile on no disk still waits for a slot before asking a server")
    func unstoredTileWaitsForASlot() async {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let gate = TileLoadGate()
        let renderer = renderer(on: stub, gate: gate)
        let slots = await fillEverySlot(of: gate, from: renderer)

        let unstored = Self.path(slots)
        renderer.loadTileForTesting(at: unstored)
        await settle { await gate.testState.interactiveWaiters == 1 }

        #expect(await gate.testState.interactiveWaiters == 1, "it queues for a slot")
        #expect(StubTileProtocol.requestCount == slots, "and opens no request while it waits")

        await drain(gate)
        #expect(StubTileProtocol.requestCount == slots + 1, "then asks, once, when a slot frees")
        #expect(stub.cache.memoryImage(forKey: Self.key(for: unstored)) != nil)
    }

    /// Saved coverage past its age is drawn the same way, ahead of the
    /// refresh that may replace it, and the refresh still waits for a slot
    /// like every request. A map downloaded more than a week before a hike is
    /// this case throughout, and it used to wait out a slot and then its own
    /// request before any of it appeared.
    @Test("saved coverage past its age is drawn while slow requests hold every slot, then refreshed")
    func staleCoverageIsDrawnAheadOfItsRefresh() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let gate = TileLoadGate()
        let renderer = renderer(on: stub, gate: gate)
        let slots = await fillEverySlot(of: gate, from: renderer)

        let stale = Self.path(slots)
        let key = Self.key(for: stale)
        let file = stub.savedFile(for: key)
        try stub.place(in: file, agedByDays: Self.staleByDays)
        let savedAt = try Self.modificationDate(of: file)
        renderer.loadTileForTesting(at: stale)

        await settleDelegateHop(until: "the saved copy to reach the memory tier the map draws from") {
            stub.cache.memoryImage(forKey: key) != nil && renderer.redrawCount(at: stale) == 1
        }
        await settle { await gate.testState.interactiveWaiters == 1 }
        #expect(await gate.testState.interactiveWaiters == 1, "its refresh still queues for a slot")
        #expect(StubTileProtocol.requestCount == slots, "and asks nothing until one frees")
        #expect(try Self.modificationDate(of: file) == savedAt, "the saved copy is left on disk as it was meanwhile")

        await drain(gate)
        await settleDelegateHop(until: "the refreshed tile to be drawn over the saved copy") {
            renderer.redrawCount(at: stale) == 2
        }
        #expect(StubTileProtocol.requestCount == slots + 1, "the refresh was asked for, once, when a slot freed")
        #expect(Self.holdsCurrentTile(stub.cache, forKey: key), "memory holds the fresh bytes, not the stale copy")
        #expect(!stub.cache.isExpired(try Self.modificationDate(of: file)), "and so does the saved file")
        #expect(!stub.isBrowsed(key), "written back into the durable tier, not beside it")
        #expect(renderer.refreshCounts == (underWay: 0, failed: 0))
    }
}
