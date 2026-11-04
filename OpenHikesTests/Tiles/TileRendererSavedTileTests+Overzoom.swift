//
//  TileRendererSavedTileTests+Overzoom.swift
//  OpenHikesTests
//
//  Saved coverage past its age, drawn from anywhere but its own screen tile.
//  Past a source's deepest zoom every screen tile is a crop of one real tile,
//  and most of those crops find the saved copy in memory, so they have nothing
//  to wait for and nothing records them. When the refresh behind the copy
//  lands, each still has to be drawn again.
//
//  A renderer outside a map view draws nothing, so what is checked is the
//  decision: which map rects a refresh asks MapKit for. That MapKit then
//  draws them is the assumption AGENTS.md lists under *Load-bearing but never
//  observed*.
//
//  An extension of `TileRendererSavedTileTests` rather than a suite of its
//  own, for the reason `TileRendererSavedTileTests+StaleCoverage.swift` gives.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension TileRendererSavedTileTests {
    /// The deepest zoom these tests' tile source has.
    private static let deepestZ = 19

    private static let sourceColumn = 275_200
    private static let sourceRow = 185_600

    /// A real tile at that zoom, saved a day past its age.
    private static let source = MKTileOverlayPath(
        x: sourceColumn,
        y: sourceRow,
        z: deepestZ,
        contentScaleFactor: 2
    )

    /// Where `path` lies on the map, worked out here rather than asked of the
    /// renderer, so a wrong answer there cannot agree with itself.
    private static func mapRect(of path: MKTileOverlayPath) -> MKMapRect {
        let side = MKMapSize.world.width / Double(1 << path.z)
        return MKMapRect(x: Double(path.x) * side, y: Double(path.y) * side, width: side, height: side)
    }

    /// The screen tile in the top left corner of ``source`` at `zoom`.
    private static func firstCrop(atZoom zoom: Int) -> MKTileOverlayPath {
        let scale = 1 << (zoom - deepestZ)
        return MKTileOverlayPath(x: source.x * scale, y: source.y * scale, z: zoom, contentScaleFactor: 2)
    }

    /// The screen tile in the bottom right corner of ``source`` at `zoom`, as
    /// far from ``firstCrop(atZoom:)`` as a crop gets. At ``deepestZ`` it is
    /// the tile itself.
    private static func lastCrop(atZoom zoom: Int) -> MKTileOverlayPath {
        let scale = 1 << (zoom - deepestZ)
        return MKTileOverlayPath(
            x: source.x * scale + scale - 1,
            y: source.y * scale + scale - 1,
            z: zoom,
            contentScaleFactor: 2
        )
    }

    private func overzoomedRenderer(on stub: StubbedTileCache) throws -> CachingTileOverlayRenderer {
        try stub.place(in: stub.savedFile(for: Self.key(for: Self.source)), agedByDays: Self.staleByDays)
        let overlay = TileOverlay(
            providerID: Self.providerID,
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: stub.cache,
            autoSaveStore: stub.store
        )
        overlay.maximumZ = Self.deepestZ
        return CachingTileOverlayRenderer(overlay: overlay, gate: TileLoadGate())
    }

    /// One draw pass over the screen tile at `rect`, which MapKit would make
    /// at the scale that draws an overlay tile one tile wide. Inset, so the
    /// pass covers this tile and not its neighbours.
    private func draw(_ rect: MKMapRect, on renderer: CachingTileOverlayRenderer) throws {
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let tileWidth = 256.0
        renderer.draw(
            rect.insetBy(dx: rect.width / 4, dy: rect.height / 4),
            zoomScale: MKZoomScale(tileWidth / rect.width),
            in: context
        )
    }

    /// Draws a first crop, which misses and so reads the saved copy, and waits
    /// until that copy is drawn and its refresh is held open at the server.
    /// Everything drawn after this finds the copy in memory.
    private func drawCopyAheadOfItsRefresh(
        from rect: MKMapRect,
        on renderer: CachingTileOverlayRenderer
    ) async throws {
        StubTileProtocol.alwaysRespond(with: .tile())
        StubTileProtocol.holdResponses()
        try draw(rect, on: renderer)
        await settleDelegateHop(until: "the saved copy to be drawn and its refresh to reach the server") {
            renderer.redrawCount(at: Self.source) == 1 && StubTileProtocol.requestCount == 1
        }
    }

    private func landRefresh(on renderer: CachingTileOverlayRenderer) async {
        StubTileProtocol.releaseResponses()
        await settleDelegateHop(until: "the refresh to land and ask for a redraw") {
            renderer.redrawCount(at: Self.source) == 2
        }
    }

    /// The headline. The later rect found the copy in memory, so it waited
    /// for nothing and is on no list, and it still has to change: at the zooms
    /// past the source it is a crop of the refreshed tile, and at the source's
    /// own zoom it is the tile, zoomed back out to.
    @Test("a refresh redraws what was drawn from its copy after the copy reached memory", arguments: [19, 20, 21, 22])
    func refreshReachesEveryCrop(drawnAtZoom zoom: Int) async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let renderer = try overzoomedRenderer(on: stub)
        let asker = Self.mapRect(of: Self.firstCrop(atZoom: 21))
        let later = Self.mapRect(of: Self.lastCrop(atZoom: zoom))
        try await drawCopyAheadOfItsRefresh(from: asker, on: renderer)

        try draw(later, on: renderer)
        await landRefresh(on: renderer)

        let redrawn = renderer.latestRedraw(at: Self.source)
        #expect(redrawn.contains { $0.contains(asker) }, "the rect that read the copy, as it always was")
        #expect(redrawn.contains { $0.contains(later) }, "and the one that found it in memory")
    }

    /// And no further than the tile. The rects that read the copy lie inside
    /// it, so asking for them as well would only ask twice, and a rect past
    /// the tile would draw ground nothing changed.
    @Test("a refresh asks for its tile's ground, once")
    func refreshAsksForTheTileAlone() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let renderer = try overzoomedRenderer(on: stub)
        try await drawCopyAheadOfItsRefresh(from: Self.mapRect(of: Self.firstCrop(atZoom: 21)), on: renderer)

        await landRefresh(on: renderer)

        let redrawn = renderer.latestRedraw(at: Self.source)
        #expect(redrawn.count == 1)
        #expect(redrawn.allSatisfy { MKMapRectEqualToRect($0, Self.mapRect(of: Self.source)) })
    }

    /// `draw` wraps a column past the edge of the world back onto the tile it
    /// shows, so the rect it drew lies a world away from the tile's own, and
    /// only its own redraw reaches it there.
    @Test("a refresh still redraws a rect drawn past the edge of the world")
    func refreshKeepsARectPastTheWorldsEdge() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let renderer = try overzoomedRenderer(on: stub)
        let tile = Self.mapRect(of: Self.source)
        let wrapped = tile.offsetBy(dx: MKMapSize.world.width, dy: 0)
        try await drawCopyAheadOfItsRefresh(from: wrapped, on: renderer)

        await landRefresh(on: renderer)

        let redrawn = renderer.latestRedraw(at: Self.source)
        #expect(redrawn.contains { $0.contains(wrapped) }, "where it was drawn")
        #expect(redrawn.contains { $0.contains(tile) }, "as well as where the tile lies")
    }

    /// What the redraw stands on: a draw finds the fresh bytes in memory, so
    /// it reads no disk and asks no server, and it has nothing to redraw in
    /// turn. Drawing a crop while the refresh is out asks for nothing either,
    /// so the crops of one tile cost one request however many there are.
    @Test("the crops of a refreshed tile cost one request and draw again from memory")
    func cropsCostNothingMore() async throws {
        let stub = StubbedTileCache()
        defer { stub.tearDown() }
        let renderer = try overzoomedRenderer(on: stub)
        let first = Self.mapRect(of: Self.firstCrop(atZoom: 21))
        let last = Self.mapRect(of: Self.lastCrop(atZoom: 21))
        try await drawCopyAheadOfItsRefresh(from: first, on: renderer)
        try draw(last, on: renderer)
        #expect(renderer.refreshCounts.underWay == 1, "precondition: the refresh is still out")
        await landRefresh(on: renderer)
        #expect(Self.holdsCurrentTile(stub.cache, forKey: Self.key(for: Self.source)))

        try draw(first, on: renderer)
        try draw(last, on: renderer)

        await settleDelegateHop(until: "the refresh's own bookkeeping to end") {
            renderer.refreshCounts == (underWay: 0, failed: 0)
        }
        #expect(StubTileProtocol.requestCount == 1, "one refresh for the tile, and nothing since")
        #expect(renderer.redrawCount(at: Self.source) == 2, "and a crop drawn from memory asks for no redraw")
    }
}
