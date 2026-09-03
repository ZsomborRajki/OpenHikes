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

    /// The path portion of a cache key. `TileCacheKey.namespaced` prefixes the
    /// provider id before a tile is stored under it. Scale is not in there —
    /// see ``TileCacheKey`` — so the only thing that can separate two keys is
    /// the tile they name.
    @Test("the cache key identifies zoom and position, and nothing else")
    func cacheKey() {
        #expect(MKTileOverlayPath(x: 3, y: 4, z: 5, contentScaleFactor: 2).cacheKey == "5/3/4")
        #expect(MKTileOverlayPath(x: 3, y: 4, z: 5, contentScaleFactor: 3).cacheKey == "5/3/4")
        #expect(MKTileOverlayPath(x: 4, y: 3, z: 5, contentScaleFactor: 2).cacheKey != "5/3/4")
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

    // MARK: Not asking for a tile that is already here

    /// The arithmetic above is only half of overzoom. The other half is
    /// knowing when *not* to fetch, and getting it wrong does not show the
    /// wrong ground — it burns the battery of a phone sitting on a table.
    ///
    /// Below `maximumZ` the drawn key and the fetched key are the same, so a
    /// cache hit is resolved by `draw` before this is ever consulted and the
    /// answer is simply "fetch it".
    @Test("a tile within the provider's zoom range is fetched as itself")
    func withinRangeFetchesItself() {
        let path = MKTileOverlayPath(x: 8723, y: 5685, z: 14, contentScaleFactor: 2)
        let fetch = CachingTileOverlayRenderer.fetchPath(
            drawing: path,
            maximumZ: 19
        ) { _ in
            Issue.record("nothing above maximumZ, so nothing to ask about")
            return false
        }
        #expect(fetch?.z == 14)
        #expect(fetch?.x == path.x)
        #expect(fetch?.y == path.y)
    }

    /// Past `maximumZ` with a cold cache: fetch the ancestor the bytes will
    /// be filed under, not the screen path, which no server has.
    @Test("an overzoomed tile with nothing cached fetches its deepest real ancestor")
    func overzoomedColdFetchesAncestor() {
        let path = MKTileOverlayPath(x: 34_892, y: 22_740, z: 21, contentScaleFactor: 2)
        let fetch = CachingTileOverlayRenderer.fetchPath(
            drawing: path,
            maximumZ: 19
        ) { _ in false }
        #expect(fetch?.z == 19)
        #expect(fetch?.x == path.x >> 2)
        #expect(fetch?.y == path.y >> 2)
    }

    /// The headline, and the whole reason this seam exists.
    ///
    /// `draw` looks a tile up under the *screen* path while the bytes are
    /// filed under the ancestor, so above `maximumZ` the lookup misses on
    /// every pass however warm the cache is. Answering with a path there makes
    /// the load hit memory, report success, and redraw — which misses again:
    /// one task, two gate hops and a main-thread redraw per visible tile,
    /// forever, on an idle device. A pinch past z19 on OpenStreetMap, the
    /// keyless default, is enough to reach it.
    @Test("an overzoomed tile whose ancestor is already in memory is not fetched")
    func overzoomedWarmDoesNotFetch() {
        let path = MKTileOverlayPath(x: 34_892, y: 22_740, z: 21, contentScaleFactor: 2)
        let ancestor = path.ancestor(atZoom: 19)

        var asked: [String] = []
        let fetch = CachingTileOverlayRenderer.fetchPath(
            drawing: path,
            maximumZ: 19
        ) { candidate in
            asked.append(candidate.cacheKey)
            return candidate.cacheKey == ancestor.cacheKey
        }

        #expect(fetch == nil, "the bytes are already in memory — there is nothing to fetch or invalidate")
        #expect(asked == [ancestor.cacheKey], "asked about the key the bytes are filed under, not the drawn one")
    }

    /// And the tile is still requested once. A warm *screen* path proves
    /// nothing above `maximumZ` — nothing ever files bytes there — so the
    /// question has to be asked about the ancestor or an overzoomed region
    /// would never load at all.
    @Test("an overzoomed tile is fetched when only the drawn path looks cached")
    func overzoomedIgnoresTheDrawnPath() {
        let path = MKTileOverlayPath(x: 34_892, y: 22_740, z: 21, contentScaleFactor: 2)
        let fetch = CachingTileOverlayRenderer.fetchPath(
            drawing: path,
            maximumZ: 19
        ) { $0.cacheKey == path.cacheKey }
        #expect(fetch?.z == 19)
    }
}
