//
//  TileRendererSavedTileTests.swift
//  OpenHikesTests
//
//  A tile already on disk needs no request, and the renderer made it wait for
//  one anyway. It took a `TileLoadGate` slot before it read the disk, and a
//  slot is held for as long as a server takes to answer — on one bar on a
//  ridge, up to the session's idle timeout. Six slow requests for the tiles
//  around it kept a tile saved for offline use off the screen until one of
//  them ended.
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

    private static let providerID = "osm_saved_tile_test"

    /// One row of tiles at one zoom, none of them stored until a test puts
    /// one there.
    private static func path(_ column: Int) -> MKTileOverlayPath {
        MKTileOverlayPath(x: 8600 + column, y: 5800, z: 14, contentScaleFactor: 2)
    }

    private static func key(for path: MKTileOverlayPath) -> String {
        TileCacheKey.namespaced(providerID: providerID, z: path.z, x: path.x, y: path.y)
    }

    private func renderer(on stub: StubbedTileCache, gate: TileLoadGate) -> CachingTileOverlayRenderer {
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
    private func settle(untilTrue condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            guard await settlePollTick() else { break }
        }
    }

    /// Asks for one tile that is on no disk per slot the map can take, with
    /// every request held open, and returns the number of slots once each is
    /// held by a request on the wire. With no download running, that is all
    /// of them.
    private func fillEverySlot(of gate: TileLoadGate, from renderer: CachingTileOverlayRenderer) async -> Int {
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
    private func drain(_ gate: TileLoadGate) async {
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

    /// Saved coverage past its age is refreshed before it is drawn, and only
    /// a load holding a slot may ask for the refresh. Drawn from outside the
    /// gate instead, the old copy would answer every later pass from memory
    /// and the refresh would never be asked for at all.
    @Test("saved coverage past its age waits for the load that can refresh it")
    func staleCoverageWaitsForItsRefresh() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let gate = TileLoadGate()
        let renderer = renderer(on: stub, gate: gate)
        let slots = await fillEverySlot(of: gate, from: renderer)

        let stale = Self.path(slots)
        let key = Self.key(for: stale)
        try stub.place(in: stub.savedFile(for: key), agedByDays: 8)
        renderer.loadTileForTesting(at: stale)
        await settle { await gate.testState.interactiveWaiters == 1 }

        #expect(await gate.testState.interactiveWaiters == 1, "it queues for the slot its refresh needs")
        #expect(stub.cache.memoryImage(forKey: key) == nil, "and the old copy is not drawn in the meantime")

        await drain(gate)
        #expect(StubTileProtocol.requestCount == slots + 1, "the refresh is asked for once a slot frees")
        #expect(stub.cache.memoryImage(forKey: key) != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: stub.savedFile(for: key).path)
        let savedAt = try #require(attributes[.modificationDate] as? Date)
        #expect(!stub.cache.isExpired(savedAt), "and the saved copy is current again")
    }
}
