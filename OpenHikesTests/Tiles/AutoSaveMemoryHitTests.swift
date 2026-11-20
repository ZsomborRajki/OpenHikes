//
//  AutoSaveMemoryHitTests.swift
//  OpenHikesTests
//
//  A tile the map draws out of memory is offered to auto-save too.
//
//  Only a load used to offer one, and a draw pass that finds its tile in
//  memory starts no load. So a hiker who browsed a trail, turned *Auto-Save
//  Tiles* on and panned back over the same ground kept none of it: the tiles
//  stayed in the purgeable cache while the hike's screen said it was being
//  saved for. The draw pass now asks the store under one lock and queues the
//  tile, and a worker off the draw path moves it.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Auto-save of tiles drawn from memory")
struct AutoSaveMemoryHitTests {
    private let sandbox = TileSandbox(reachable: false)
    private let hikeID = UUID()

    private var store: AutoSaveTileStore { sandbox.store }

    /// Zoom 16's tile under the ridge fixture's third point, inside its
    /// corridor.
    private static let tile: (z: Int, x: Int, y: Int) = {
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[2]
        return (16, SlippyTileMath.tileX(anchor.longitude, z: 16), SlippyTileMath.tileY(anchor.latitude, z: 16))
    }()

    private func makeOverlay() -> TileOverlay {
        TileOverlay(
            providerID: "osm",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: sandbox.cache,
            autoSaveStore: store
        )
    }

    private static func key(for overlay: TileOverlay) -> String {
        TileCacheKey.namespaced(providerID: overlay.providerID, z: tile.z, x: tile.x, y: tile.y)
    }

    private func activate() {
        store.setActiveHike(id: hikeID, route: Fixture.coordinates(Fixture.ridgeRoute), knownKeys: [])
    }

    /// One draw pass over the tile alone, at the scale that reads as its
    /// zoom. The canvas is beside the point: what is asked is what the pass
    /// offers.
    private static func draw(_ renderer: CachingTileOverlayRenderer, overlay: TileOverlay) throws {
        let tileMapSize = MKMapSize.world.width / Double(1 << tile.z)
        let mapRect = MKMapRect(
            x: Double(tile.x) * tileMapSize,
            y: Double(tile.y) * tileMapSize,
            width: tileMapSize,
            height: tileMapSize
        )
        let context = try #require(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        renderer.draw(mapRect, zoomScale: MKZoomScale(Double(overlay.tileSize.width) / tileMapSize), in: context)
    }

    @Test("a tile browsed before auto-save took the hike on is kept once the map draws it from memory")
    func memoryHitIsSavedOnceAHikeIsActive() async throws {
        let overlay = makeOverlay()
        let key = Self.key(for: overlay)
        // Drawn once already, before the switch went on: on disk in the
        // browsing cache, and in memory.
        try sandbox.browse(key: key)
        sandbox.cache.cacheInMemory(try #require(Fixture.tileImage()), storedAt: .now, forKey: key)
        let renderer = CachingTileOverlayRenderer(overlay: overlay)
        try Self.draw(renderer, overlay: overlay)
        await store.waitForMemoryOffers()
        #expect(!sandbox.isSaved(key), "precondition: with no hike being saved for, nothing is kept")

        activate()
        try Self.draw(renderer, overlay: overlay)
        await store.waitForMemoryOffers()

        #expect(sandbox.isSaved(key), "the pan back over it keeps it")
        #expect(store.drainPendingKeys(for: hikeID) == [key], "for the hike being saved for")
    }

    /// The draw pass runs many times a second while the map moves. A tile
    /// turned down once — here, one in memory with no copy on disk to move —
    /// is not queued again on every pass, until the store takes a hike on
    /// anew.
    @Test("a tile is queued from memory once for each hike taken on")
    func memoryHitIsQueuedOncePerHike() async throws {
        let (z, x, y) = Self.tile
        let key = "osm/\(z)/\(x)/\(y)"
        activate()

        store.offerTileDrawnFromMemory(z: z, x: x, y: y) { key }
        await store.waitForMemoryOffers()
        #expect(!sandbox.isSaved(key), "precondition: no bytes on disk, so nothing to move")

        try sandbox.browse(key: key)
        store.offerTileDrawnFromMemory(z: z, x: x, y: y) { key }
        await store.waitForMemoryOffers()
        #expect(!sandbox.isSaved(key), "queued once already for this hike")

        activate()
        store.offerTileDrawnFromMemory(z: z, x: x, y: y) { key }
        await store.waitForMemoryOffers()
        #expect(sandbox.isSaved(key), "a hike taken on anew is offered it again")
    }

    /// The draw pass's cost with auto-save off, which is the default: one
    /// lock, and the key never made.
    @Test("with no hike being saved for, the draw pass makes no key and queues nothing")
    func idleStoreMakesNoKey() async {
        nonisolated(unsafe) var madeKey = false
        store.offerTileDrawnFromMemory(z: Self.tile.z, x: Self.tile.x, y: Self.tile.y) {
            madeKey = true
            return "osm/never"
        }
        await store.waitForMemoryOffers()
        #expect(!madeKey)
    }
}
