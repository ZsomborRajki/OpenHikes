//
//  TileRendererTileRangeTests.swift
//  OpenHikesTests
//
//  Which tiles one draw pass looks up. MapKit's draw rects are aligned to tile
//  edges, so a rect's far edge is the near edge of the next tile over, and
//  that tile is not the pass's to draw: a miss on it would start a load, and
//  for saved coverage past its age a refresh, for ground outside the rect.
//
//  Checked by drawing. Every tile around the rect is already in the memory
//  tier, and the canvas spans them all, so a tile the pass looks up is a tile
//  it paints, and a tile it paints outside the rect is one it had no business
//  asking for. Nothing is missed, so nothing loads.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Tile renderer tile range")
struct TileRendererTileRangeTests {
    struct Tile: Hashable, CustomStringConvertible {
        let x: Int
        let y: Int
        var description: String { "\(x)/\(y)" }
    }

    private static let zoom = 10
    private static let tileCount = 1 << zoom
    private static let tileMapSize = MKMapSize.world.width / Double(tileCount)
    private static let pixelsPerTile = 8

    /// An Alpine column and row at ``zoom``.
    private static let column = 544
    private static let row = 360

    /// The ground of the tiles in `columns` and `rows`, which may lie past the
    /// edge of the world as MapKit's rects can.
    private static func mapRect(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> MKMapRect {
        MKMapRect(
            x: Double(columns.lowerBound) * tileMapSize,
            y: Double(rows.lowerBound) * tileMapSize,
            width: Double(columns.count) * tileMapSize,
            height: Double(rows.count) * tileMapSize
        )
    }

    private static func tiles(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> Set<Tile> {
        Set(columns.flatMap { x in rows.map { Tile(x: x, y: $0) } })
    }

    private func solidTile() -> TileImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        #else
        let image = NSImage(size: CGSize(width: 256, height: 256))
        image.lockFocus()
        NSColor.red.setFill()
        CGRect(x: 0, y: 0, width: 256, height: 256).fill()
        image.unlockFocus()
        return image
        #endif
    }

    /// Draws `mapRect` in one pass, with every tile of `columns` and `rows` in
    /// memory and a canvas spanning exactly those tiles, and reports which of
    /// them were painted.
    ///
    /// A column past the edge of the world is cached under the column it wraps
    /// onto, and a row past it under the row it is clamped to, because that
    /// is the ground the renderer would draw there.
    private func paintedTiles(
        drawing mapRect: MKMapRect,
        around columns: ClosedRange<Int>,
        _ rows: ClosedRange<Int>
    ) throws -> Set<Tile> {
        let sandbox = TileSandbox(reachable: false)
        let overlay = TileOverlay(
            providerID: "range_test",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: sandbox.cache,
            autoSaveStore: sandbox.store
        )
        let image = solidTile()
        for tile in Self.tiles(columns: columns, rows: rows) {
            let key = TileCacheKey.namespaced(
                providerID: overlay.providerID,
                z: Self.zoom,
                x: SlippyTileMath.wrap(tile.x, to: Self.tileCount),
                y: SlippyTileMath.clamp(tile.y, to: Self.tileCount)
            )
            sandbox.cache.cacheInMemory(image, storedAt: Date(), forKey: key)
        }
        let renderer = CachingTileOverlayRenderer(overlay: overlay)

        let ppt = Self.pixelsPerTile
        let width = columns.count * ppt
        let height = rows.count * ppt
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Flipped as MapKit's contexts are, so a row of memory is a row of
        // map, then scaled and moved so the canvas spans the tiles around.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let pixelsPerMapPoint = Double(ppt) / Self.tileMapSize
        context.scaleBy(x: pixelsPerMapPoint, y: pixelsPerMapPoint)
        context.translateBy(
            x: -Double(columns.lowerBound) * Self.tileMapSize,
            y: -Double(rows.lowerBound) * Self.tileMapSize
        )
        // The scale at which one of the overlay's tiles is one tile wide on
        // screen, which is what makes the renderer read the level as ``zoom``.
        let zoomScale = MKZoomScale(Double(overlay.tileSize.width) / Self.tileMapSize)
        renderer.draw(mapRect, zoomScale: zoomScale, in: context)

        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Self.tiles(columns: columns, rows: rows).filter { tile in
            let pixelX = (tile.x - columns.lowerBound) * ppt + ppt / 2
            let pixelY = (tile.y - rows.lowerBound) * ppt + ppt / 2
            return pixels[(pixelY * width + pixelX) * 4 + 3] != 0
        }
    }

    /// The headline. MapKit draws an overlay one, two or four tiles across a
    /// side, by its own tile size against the overlay's (the iOS 27.2
    /// simulator draws 512 points, two of these across), and each of those
    /// passes is its own tiles and nothing else.
    @Test("a tile-aligned rect draws exactly its own tiles", arguments: [1, 2, 4])
    func alignedRectDrawsItsOwnTiles(tilesAcross span: Int) throws {
        let columns = Self.column...(Self.column + span - 1)
        let rows = Self.row...(Self.row + span - 1)

        let painted = try paintedTiles(
            drawing: Self.mapRect(columns: columns, rows: rows),
            around: (columns.lowerBound - 1)...(columns.upperBound + 1),
            (rows.lowerBound - 1)...(rows.upperBound + 1)
        )

        #expect(painted == Self.tiles(columns: columns, rows: rows))
    }

    /// The other side of the edge: a rect that ends partway into a tile needs
    /// that tile, since part of the rect is its ground.
    @Test("a rect that ends partway into a tile draws that tile too")
    func partialRectDrawsEveryTileItTouches() throws {
        let side = Self.tileMapSize
        let mapRect = MKMapRect(
            x: (Double(Self.column) + 0.5) * side,
            y: (Double(Self.row) + 0.25) * side,
            width: side,
            height: side / 2
        )

        let painted = try paintedTiles(
            drawing: mapRect,
            around: (Self.column - 1)...(Self.column + 2),
            (Self.row - 1)...(Self.row + 1)
        )

        #expect(painted == Self.tiles(columns: Self.column...(Self.column + 1), rows: Self.row...Self.row))
    }

    /// The guard on the range. A rect with no width, or no height, lying on a
    /// tile edge would end the range one tile before it starts, which traps.
    /// It covers the tile it sits in instead, the one past that edge.
    @Test("a rect with no width or no height on a tile edge draws the one tile past it", arguments: [true, false])
    func flatRectOnAnEdgeDrawsOneTile(hasNoWidth: Bool) throws {
        let side = Self.tileMapSize
        let mapRect = MKMapRect(
            x: Double(Self.column) * side,
            y: Double(Self.row) * side,
            width: hasNoWidth ? 0 : side,
            height: hasNoWidth ? side : 0
        )

        let painted = try paintedTiles(
            drawing: mapRect,
            around: (Self.column - 1)...(Self.column + 1),
            (Self.row - 1)...(Self.row + 1)
        )

        #expect(painted == [Tile(x: Self.column, y: Self.row)])
    }

    /// A rect a world to the east, as MapKit draws while panning across the
    /// antimeridian, still draws the tiles it wraps onto, and only those.
    @Test("an aligned rect past the antimeridian draws the tiles it wraps onto and none beyond")
    func rectPastTheAntimeridianWraps() throws {
        let columns = Self.tileCount...(Self.tileCount + 1)
        let rows = Self.row...(Self.row + 1)

        let painted = try paintedTiles(
            drawing: Self.mapRect(columns: columns, rows: rows),
            around: (Self.tileCount - 1)...(Self.tileCount + 2),
            (Self.row - 1)...(Self.row + 2)
        )

        #expect(painted == Self.tiles(columns: columns, rows: rows))
    }

    /// The last rows of the world end at its bottom edge. The row past it is
    /// clamped onto the last one, so looking it up would draw that row a
    /// second time, below the world.
    @Test("an aligned rect on the world's bottom edge draws no row past it")
    func rectOnTheBottomEdgeStopsThere() throws {
        let columns = Self.column...(Self.column + 1)
        let rows = (Self.tileCount - 2)...(Self.tileCount - 1)

        let painted = try paintedTiles(
            drawing: Self.mapRect(columns: columns, rows: rows),
            around: (Self.column - 1)...(Self.column + 2),
            (Self.tileCount - 3)...Self.tileCount
        )

        #expect(painted == Self.tiles(columns: columns, rows: rows))
    }
}
