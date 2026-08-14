//
//  TileOverzoomTests.swift
//  OpenHikesTests
//
//  Zooming past a provider's deepest real zoom, or past what's cached,
//  doesn't leave a blank map: the renderer walks up the tile pyramid to a
//  tile it does have and crops the right quadrant out of it. That walk is
//  pure index arithmetic, and getting it wrong shows the wrong piece of
//  ground under the trail rather than nothing at all.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Tile pyramid")
struct TileOverzoomTests {
    @Test("a tile's parent is the one containing it, one zoom out")
    func parent() {
        let path = MKTileOverlayPath(x: 8723, y: 5685, z: 14, contentScaleFactor: 2)
        let parent = path.parent
        #expect(parent.z == 13)
        #expect(parent.x == 4361)
        #expect(parent.y == 2842)
        #expect(parent.contentScaleFactor == 2)
    }

    /// Each of the four children of a tile has to walk back to that same
    /// tile — that's what makes the crop quadrant well defined.
    @Test("all four children share a parent")
    func childrenShareParent() {
        let parent = MKTileOverlayPath(x: 4361, y: 2842, z: 13, contentScaleFactor: 2)
        for dx in 0...1 {
            for dy in 0...1 {
                let child = MKTileOverlayPath(
                    x: parent.x * 2 + dx,
                    y: parent.y * 2 + dy,
                    z: parent.z + 1,
                    contentScaleFactor: 2
                )
                #expect(child.parent.x == parent.x)
                #expect(child.parent.y == parent.y)
                #expect(child.parent.z == parent.z)
            }
        }
    }

    /// Walking up N levels divides the indices by 2^N — this is what the
    /// renderer does when the map is zoomed past the provider's maximum.
    @Test("walking up to a zoom level lands on the containing tile", arguments: [19, 17, 14, 10])
    func ancestorAtZoom(targetZoom: Int) {
        let path = MKTileOverlayPath(x: 1_398_101, y: 909_567, z: 21, contentScaleFactor: 3)
        let ancestor = path.ancestor(atZoom: targetZoom)
        let shift = path.z - targetZoom
        #expect(ancestor.z == targetZoom)
        #expect(ancestor.x == path.x >> shift)
        #expect(ancestor.y == path.y >> shift)
        #expect(ancestor.contentScaleFactor == 3)
    }

    /// Asking for the ancestor at (or below) a tile's own zoom returns the
    /// tile — the renderer only fetches a deeper-zoom ancestor when the tile
    /// is past the provider's maximum, and must not walk when it isn't.
    @Test("a tile is its own ancestor at its own zoom or deeper")
    func ancestorNotDeeperThanSelf() {
        let path = MKTileOverlayPath(x: 8723, y: 5685, z: 14, contentScaleFactor: 2)
        for zoom in [14, 15, 19] {
            let ancestor = path.ancestor(atZoom: zoom)
            #expect(ancestor.z == path.z)
            #expect(ancestor.x == path.x)
            #expect(ancestor.y == path.y)
        }
    }

    /// The cache key is the tile's identity everywhere — memory, both disk
    /// tiers, the auto-save manifest and the bulk-download bookkeeping.
    @Test("the cache key identifies zoom, position and scale")
    func cacheKey() {
        #expect(MKTileOverlayPath(x: 3, y: 4, z: 5, contentScaleFactor: 2).cacheKey == "5/3/4@2.0")
        #expect(MKTileOverlayPath(x: 3, y: 4, z: 5, contentScaleFactor: 3).cacheKey == "5/3/4@3.0")
        #expect(MKTileOverlayPath(x: 4, y: 3, z: 5, contentScaleFactor: 2).cacheKey != "5/3/4@2.0")
    }

    @Test("fallback source region maps to the whole destination tile")
    func fallbackDrawingGeometry() {
        let path = MKTileOverlayPath(x: 3, y: 2, z: 2, contentScaleFactor: 2)
        let source = cropRect(depth: 1, path: path, imageSize: CGSize(width: 256, height: 256))
        #expect(source == CGRect(x: 128, y: 0, width: 128, height: 128))

        let destination = CGRect(x: 10, y: 20, width: 256, height: 256)
        let imageRect = scaledImageRect(
            imageSize: CGSize(width: 256, height: 256),
            sourceRect: source,
            destinationRect: destination
        )
        #expect(imageRect == CGRect(x: -246, y: 20, width: 512, height: 512))
    }
}
