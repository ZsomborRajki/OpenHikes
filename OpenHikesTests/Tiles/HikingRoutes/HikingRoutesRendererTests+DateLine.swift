//
//  HikingRoutesRendererTests+DateLine.swift
//  OpenHikesTests
//
//  The hiking-routes layer where the map's two edges meet. MapKit names every
//  tile on the world's own copy — a map centred on the 180th meridian asks
//  for the last tiles and the first, and moves them beside each other itself
//  — so a way across the antimeridian has to be drawn short into both, and
//  never as a line across the whole map from one of its ends to the other.
//
//  An extension of `HikingRoutesRendererTests` rather than a suite of its
//  own, so that its tiles are drawn the way that suite draws them.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension HikingRoutesRendererTests {
    /// Across Taveuni, in Fiji, which the antimeridian cuts.
    private static let taveuni = -16.8
    private static let detailZoom = 14
    private static let unitsPerDegree: Int32 = 1_000_000

    /// A square file of one route along `longitudes`, at `latitude`.
    private static func file(
        network: String,
        latitude: Double,
        longitudes: [Double],
        ref: String? = nil
    ) -> RouteSquareFile {
        var tags = ["network": network]
        tags["ref"] = ref
        let scale = Double(unitsPerDegree)
        return RouteSquareFile(
            routes: [RouteSquareFile.Route(id: 1, tags: tags)],
            lines: [
                RouteSquareFile.Line(
                    network: RouteNetwork(tag: network),
                    routes: [0],
                    points: longitudes.map { longitude in
                        RouteSquareFile.Point(
                            latitude: Int32((latitude * scale).rounded()),
                            longitude: Int32((longitude * scale).rounded())
                        )
                    }
                ),
            ],
            coordinateScale: unitsPerDegree
        )
    }

    /// A renderer whose database holds `file` in the detail squares at
    /// `longitudes`, and has no record of any other.
    private static func renderer(
        holding file: RouteSquareFile,
        latitude: Double,
        inSquaresAt longitudes: [Double]
    ) -> HikingRoutesRenderer {
        let encoded = file.encoded()
        let cells = Dictionary(uniqueKeysWithValues: longitudes.map { longitude in
            let square = RouteSquareGrid.square(at: .detail, latitude: latitude, longitude: longitude)
            return (RouteSquareGrid.recordName(for: square), TrailCellFetch.Cell.found(encoded))
        })
        let squares = HikingRouteSquares(database: StubTrailCellDatabase(cells: cells), directory: nil)
        return HikingRoutesRenderer(overlay: HikingRoutesOverlay(squares: squares))
    }

    /// Whether nothing at all is drawn in `image`.
    private static func isClear(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        return (0..<image.height).allSatisfy { row in
            (0..<image.width).allSatisfy { bytes[row * image.bytesPerRow + $0 * 4 + 3] == 0 }
        }
    }

    @Test("a tile at either edge of the map needs the squares across the antimeridian its reach crosses into")
    func squaresAcrossTheDateLine() {
        let scale = Self.zoomScale(Self.detailZoom)
        let east = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: 179.99)
        let west = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: -179.99)
        let last = RouteSquareGrid.square(at: .detail, latitude: Self.taveuni, longitude: 179.99)
        let first = RouteSquareGrid.square(at: .detail, latitude: Self.taveuni, longitude: -179.99)
        #expect(Set(HikingRoutesDrawing.neededSquares(for: east, zoomScale: scale)) == [last, first])
        #expect(Set(HikingRoutesDrawing.neededSquares(for: west, zoomScale: scale)) == [last, first])
    }

    /// A build that took the way's box the long way round filed it in every
    /// square around the world, Greenwich's among them, and the way itself is
    /// stored from either end.
    @Test(
        "a route across the date line is drawn at both edges of the map, and nowhere near Greenwich",
        arguments: [[179.9, -179.9], [-179.9, 179.9]]
    )
    func routeAcrossTheDateLine(longitudes: [Double]) async throws {
        let scale = Self.zoomScale(Self.detailZoom)
        let east = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: 179.99)
        let west = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: -179.99)
        let greenwich = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: 0.01)
        let renderer = Self.renderer(
            holding: Self.file(network: "nwn", latitude: Self.taveuni, longitudes: longitudes),
            latitude: Self.taveuni,
            inSquaresAt: [179.99, -179.99, 0.01]
        )
        await settleDelegateHop(until: "the three tiles' squares are in memory") {
            [east, west, greenwich].allSatisfy { renderer.canDraw($0, zoomScale: scale) }
        }

        let last = try #require(Self.draw(east, zoomScale: scale, with: renderer))
        let first = try #require(Self.draw(west, zoomScale: scale, with: renderer))
        let lineY = Int((MKMapPoint(CLLocationCoordinate2D(latitude: Self.taveuni, longitude: 0)).y - east.minY)
            / east.height * Self.tileSide)
        for x in [2, Int(Self.tileSide) - 3] {
            let inLast = Self.pixel(in: last, x: x, y: lineY)
            let inFirst = Self.pixel(in: first, x: x, y: lineY)
            #expect(inLast.alpha == 255 && inLast.blue > 200, "the last tile draws the way up to the map's edge")
            #expect(inFirst.alpha == 255 && inFirst.blue > 200, "and the first tile goes on with it")
        }
        let middle = try #require(Self.draw(greenwich, zoomScale: scale, with: renderer))
        #expect(Self.isClear(middle), "nothing joins the two ends across the map")
    }

    /// MapKit was seen naming the tiles at the seam on the world's own copy,
    /// on a simulator only. Were it to name one a world's width further east
    /// or west instead, as a map across the seam could, the tile is drawn
    /// just the same, so the layer does not rest on which.
    @Test(
        "a tile named past the edge of the map is drawn as the same tile on the world's own copy",
        arguments: [[179.9, -179.9], [-179.9, 179.9]]
    )
    func tileNamedPastTheEdge(longitudes: [Double]) async throws {
        let scale = Self.zoomScale(Self.detailZoom)
        let world = MKMapSize.world.width
        let east = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: 179.99)
        let west = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: -179.99)
        let tiles = [(east, east.offsetBy(dx: -world, dy: 0)), (west, west.offsetBy(dx: world, dy: 0))]
        let renderer = Self.renderer(
            holding: Self.file(network: "nwn", latitude: Self.taveuni, longitudes: longitudes, ref: "7"),
            latitude: Self.taveuni,
            inSquaresAt: [179.99, -179.99]
        )
        await settleDelegateHop(until: "every tile's squares are in memory") {
            tiles.allSatisfy { renderer.canDraw($0.0, zoomScale: scale) && renderer.canDraw($0.1, zoomScale: scale) }
        }

        for (own, past) in tiles {
            let drawn = try #require(Self.draw(own, zoomScale: scale, with: renderer))
            let drawnPast = try #require(Self.draw(past, zoomScale: scale, with: renderer))
            #expect(!Self.isClear(drawn), "the way crosses both tiles")
            #expect(drawn.dataProvider?.data as Data? == drawnPast.dataProvider?.data as Data?)
        }
    }

    /// A short way centred on the date line has one sign, standing on it.
    @Test("a sign on the date line is drawn whole: half in the map's last tile, half in its first")
    func signOnTheDateLine() async throws {
        let scale = Self.zoomScale(Self.detailZoom)
        let east = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: 179.99)
        let west = Self.tile(at: Self.detailZoom, latitude: Self.taveuni, longitude: -179.99)
        // Through the tiles' middle row, which the sign's middle is then on.
        let latitude = MKMapPoint(x: east.midX, y: east.midY).coordinate.latitude
        let renderer = Self.renderer(
            holding: Self.file(network: "lwn", latitude: latitude, longitudes: [179.999, -179.999], ref: "7"),
            latitude: latitude,
            inSquaresAt: [179.99, -179.99]
        )
        await settleDelegateHop(until: "both tiles' squares are in memory") {
            renderer.canDraw(east, zoomScale: scale) && renderer.canDraw(west, zoomScale: scale)
        }

        let last = try #require(Self.draw(east, zoomScale: scale, with: renderer))
        let first = try #require(Self.draw(west, zoomScale: scale, with: renderer))
        // Five pixels above the line: inside the sign, clear of the line.
        let row = Int(Self.tileSide / 2) - 5
        #expect(Self.pixel(in: last, x: Int(Self.tileSide) - 3, y: row).alpha == 255, "the last tile draws half")
        #expect(Self.pixel(in: first, x: 3, y: row).alpha == 255, "and the first tile the other half")
    }
}
