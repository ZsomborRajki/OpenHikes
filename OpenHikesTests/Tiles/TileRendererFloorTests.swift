//
//  TileRendererFloorTests.swift
//  OpenHikesTests
//
//  An overlay's `minimumZ` is a floor the renderer has to keep itself: the
//  hiking-route layer sets one so it is not drawn — or fetched — at scales
//  nobody walks, and a base map, which leaves it at zero, must not notice.
//
//  Checked by drawing: the tile is already in the memory tier at both zooms,
//  so the only thing that can stop the shallower one reaching the canvas is
//  the floor.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Tile renderer floor")
struct TileRendererFloorTests {
    private static let floor = 10
    private static let canvasSide = 64

    /// A tile in the Alps at the floor; its parent is one level below it.
    private static let atFloor = MKTileOverlayPath(x: 545, y: 361, z: floor, contentScaleFactor: 1)

    private func overlay(in sandbox: TileSandbox, minimumZ: Int) -> TileOverlay {
        let overlay = TileOverlay(
            providerID: "floor_test",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: sandbox.cache,
            autoSaveStore: sandbox.store
        )
        overlay.minimumZ = minimumZ
        return overlay
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

    /// Draws `path`'s tile through a renderer into an empty canvas and
    /// reports whether anything landed on it.
    private func paints(_ path: MKTileOverlayPath, minimumZ: Int) throws -> Bool {
        let sandbox = TileSandbox(reachable: false)
        let overlay = overlay(in: sandbox, minimumZ: minimumZ)
        let key = TileCacheKey.namespaced(providerID: overlay.providerID, z: path.z, x: path.x, y: path.y)
        sandbox.cache.cacheInMemory(solidTile(), storedAt: Date(), forKey: key)
        let renderer = CachingTileOverlayRenderer(overlay: overlay)

        let tileMapSize = MKMapSize.world.width / Double(1 << path.z)
        // Inset, so the pass covers this one tile and not its neighbours,
        // which are uncached and would only spend a fetch.
        let mapRect = MKMapRect(
            x: Double(path.x) * tileMapSize,
            y: Double(path.y) * tileMapSize,
            width: tileMapSize,
            height: tileMapSize
        ).insetBy(dx: tileMapSize / 4, dy: tileMapSize / 4)
        // The scale at which one of the overlay's tiles is one tile wide on
        // screen, which is what makes the renderer read the level as `path.z`.
        let zoomScale = MKZoomScale(Double(overlay.tileSize.width) / tileMapSize)

        let side = Self.canvasSide
        let context = try #require(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // What MapKit hands a renderer: a context already scaled to the zoom
        // and translated to the rect being drawn.
        context.scaleBy(x: zoomScale, y: zoomScale)
        context.translateBy(x: -mapRect.minX, y: -mapRect.minY)
        renderer.draw(mapRect, zoomScale: zoomScale, in: context)

        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(side * side)).contains { pixels[$0 * 4 + 3] != 0 }
    }

    @Test("a cached tile at the floor is drawn")
    func drawsAtTheFloor() throws {
        #expect(try paints(Self.atFloor, minimumZ: Self.floor))
    }

    @Test("a cached tile below the floor is not drawn")
    func skipsBelowTheFloor() throws {
        #expect(try !paints(Self.atFloor.parent, minimumZ: Self.floor))
    }

    /// The base maps' case, and the reason the floor is the overlay's rather
    /// than the renderer's: with no floor set, the same tile is drawn.
    @Test("an overlay with no floor draws the same tile")
    func noFloorDrawsEverything() throws {
        #expect(try paints(Self.atFloor.parent, minimumZ: 0))
    }
}
