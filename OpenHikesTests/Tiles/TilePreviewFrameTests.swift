//
//  TilePreviewFrameTests.swift
//  OpenHikesTests
//
//  The ground a Settings map card is drawn from, and what each catalog entry
//  draws it with. The block is snapped to the tile grid so a card is a cache
//  hit the second time — a commercial source bills the first — and it has to
//  stay a real block at the edges of the projection.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Map card tile frame")
struct TilePreviewFrameTests {
    /// The coordinate sits in the block's middle half, whichever quarter of
    /// its own tile it falls in — otherwise the hiker is drawn at the edge of
    /// a card that is meant to be about where they are.
    @Test("the block holds the coordinate in its middle half", arguments: [
        CLLocationCoordinate2D(latitude: 47.5536, longitude: 12.9752),
        CLLocationCoordinate2D(latitude: -33.86, longitude: 151.21),
        CLLocationCoordinate2D(latitude: 64.14, longitude: -21.94),
        CLLocationCoordinate2D(latitude: 0.001, longitude: -0.001),
    ])
    func blockHoldsCoordinate(coordinate: CLLocationCoordinate2D) {
        let frame = TilePreviewFrame(around: coordinate)
        let count = Double(1 << frame.z)
        let column = SlippyTileMath.tileXFraction(coordinate.longitude, count: count)
        let row = SlippyTileMath.tileYFraction(coordinate.latitude, count: count)
        #expect(column >= Double(frame.x) + 0.5 && column <= Double(frame.x) + 1.5)
        #expect(row >= Double(frame.y) + 0.5 && row <= Double(frame.y) + 1.5)
    }

    /// Two positions inside the same quarter of a tile ask for the same four
    /// tiles, which is what makes a second visit free.
    @Test("nearby positions share a block")
    func nearbyPositionsShareABlock() {
        let here = TilePreviewFrame(around: CLLocationCoordinate2D(latitude: 47.5536, longitude: 12.9752))
        let close = TilePreviewFrame(around: CLLocationCoordinate2D(latitude: 47.5537, longitude: 12.9753))
        #expect(here == close)
    }

    /// Four tiles, row by row from the north-west corner, each placed where
    /// the compositor draws it.
    @Test("a block is four tiles in reading order")
    func blockIsFourTiles() {
        let frame = TilePreviewFrame(around: TilePreviewFrame.fallbackCoordinate)
        let placed = frame.tiles.map { [$0.x - frame.x, $0.y - frame.y, $0.column, $0.row] }
        #expect(placed == [[0, 0, 0, 0], [1, 0, 1, 0], [0, 1, 0, 1], [1, 1, 1, 1]])
        #expect(frame.tiles.allSatisfy { $0.z == TilePreviewFrame.defaultZoom })
    }

    /// Just west of the antimeridian the block's east column is column 0, not
    /// a column past the edge of the world that no server has.
    @Test("a block across the antimeridian wraps its columns")
    func antimeridianWraps() {
        let frame = TilePreviewFrame(around: CLLocationCoordinate2D(latitude: -17.0, longitude: 179.9999))
        let count = 1 << frame.z
        #expect(frame.x == count - 1)
        #expect(Set(frame.tiles.map(\.x)) == [count - 1, 0])
    }

    /// Near the pole the block is held inside the projection rather than
    /// asking for a row that does not exist.
    @Test("a block near the pole stays inside the projection")
    func poleIsClamped() {
        let frame = TilePreviewFrame(around: CLLocationCoordinate2D(latitude: 85.05, longitude: 10))
        #expect(frame.y == 0)
        let south = TilePreviewFrame(around: CLLocationCoordinate2D(latitude: -85.05, longitude: 10))
        #expect(south.tiles.allSatisfy { $0.y < 1 << south.z })
    }

    @Test("the unit rect is the block's own")
    func unitRectMatchesBlock() {
        let frame = TilePreviewFrame(around: TilePreviewFrame.fallbackCoordinate)
        let count = Double(1 << frame.z)
        let rect = frame.unitRect
        #expect(rect.originX == Double(frame.x) / count)
        #expect(rect.originY == Double(frame.y) / count)
        #expect(rect.side == 2 / count)
    }

    // MARK: Source

    /// The system map draws through a snapshotter, never through a template:
    /// it has none, and a URL built from an empty one would be a request to
    /// nowhere.
    @Test("Apple Maps is snapshotted, not fetched")
    func systemMapIsSnapshotted() {
        let source = TilePreviewSource(.appleMaps, apiKey: nil)
        #expect(source == .systemMap)
        let tile = TilePreviewFrame(around: TilePreviewFrame.fallbackCoordinate).tiles[0]
        #expect(source.url(for: tile) == nil)
        #expect(source.cacheKey(for: tile) == nil)
    }

    /// A key-gated source with no key asks for nothing: every answer would
    /// be a 401.
    @Test("a source missing its key draws nothing")
    func missingKeyIsUnavailable() {
        #expect(TilePreviewSource(.stadiaOutdoors, apiKey: nil) == .unavailable)
        #expect(TilePreviewSource(.stadiaOutdoors, apiKey: "") == .unavailable)
    }

    /// A card files its tiles under the key the map's overlay uses, so each
    /// reuses what the other fetched — and asks with the key resolved into
    /// the provider's own template.
    @Test("tiles are asked for, and cached, as the map asks for them")
    func tilesMatchTheMap() throws {
        let source = TilePreviewSource(.stadiaOutdoors, apiKey: "secret")
        let tile = TilePreviewFrame(around: TilePreviewFrame.fallbackCoordinate).tiles[3]
        let url = try #require(source.url(for: tile))
        #expect(url.absoluteString
            == "https://tiles.stadiamaps.com/tiles/outdoors/\(tile.z)/\(tile.x)/\(tile.y).png?api_key=secret")
        #expect(source.cacheKey(for: tile)
            == TileCacheKey.namespaced(providerID: "stadia_outdoors", z: tile.z, x: tile.x, y: tile.y))
    }

    /// The keyless default needs nothing resolved.
    @Test("a keyless source draws without a key")
    func keylessDraws() {
        let source = TilePreviewSource(.openStreetMap, apiKey: nil)
        #expect(source == .tiles(providerID: "osm", urlTemplate: TileProvider.openStreetMap.urlTemplate))
    }
}

private extension SlippyTileMath {
    static func tileXFraction(_ longitude: Double, count: Double) -> Double {
        (longitude + 180) / 360 * count
    }

    static func tileYFraction(_ latitude: Double, count: Double) -> Double {
        let radians = latitude * .pi / 180
        return (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2 * count
    }
}
