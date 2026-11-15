//
//  HikingRoutesRendererTests.swift
//  OpenHikesTests
//
//  The hiking-routes layer drawn into a tile: which level and which squares a
//  tile at a zoom needs, nothing drawn before all of them are in, a line
//  stroked in its network's colour where it runs, and a sign across the edge
//  of two tiles drawn whole.
//
//  The tile is drawn into a bitmap the way MapKit hands a renderer one: a
//  context scaled by the zoom and moved to the tile's corner.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Hiking routes renderer")
struct HikingRoutesRendererTests {
    /// The tile side MapKit draws in, in tile pixels.
    static let tileSide = 256.0

    /// The zoom scale MapKit draws zoom `zoom` at.
    static func zoomScale(_ zoom: Int) -> MKZoomScale {
        MKZoomScale(pow(2, Double(zoom) - 20))
    }

    /// The tile at `zoom` holding a point, as MapKit names its ground.
    static func tile(at zoom: Int, latitude: Double, longitude: Double) -> MKMapRect {
        let side = MKMapSize.world.width / pow(2, Double(zoom))
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        return MKMapRect(
            x: (point.x / side).rounded(.down) * side,
            y: (point.y / side).rounded(.down) * side,
            width: side,
            height: side
        )
    }

    /// A national route straight through Berchtesgaden's detail square.
    private static let file = RouteSquareFile(
        routes: [RouteSquareFile.Route(id: 18_722, tags: ["network": "nwn"])],
        lines: [
            RouteSquareFile.Line(
                network: .national,
                routes: [0],
                points: [
                    RouteSquareFile.Point(latitude: 47_550_000, longitude: 12_900_000),
                    RouteSquareFile.Point(latitude: 47_550_000, longitude: 13_100_000),
                ]
            ),
        ],
        coordinateScale: 1_000_000
    )

    @Test(
        "a tile is drawn from the level its zoom calls for, and not at all shallower than zoom 7",
        arguments: [(6, nil), (7, RouteSquareLevel.overview), (11, .region), (13, .area), (16, .detail)]
            as [(Int, RouteSquareLevel?)]
    )
    func levelForTile(zoom: Int, expected: RouteSquareLevel?) {
        #expect(HikingRoutesDrawing.zoom(for: Self.zoomScale(zoom)) == zoom)
        #expect(RouteSquareLevel.level(forZoom: HikingRoutesDrawing.zoom(for: Self.zoomScale(zoom))) == expected)
    }

    @Test("a scale no map has is no zoom the layer draws at")
    func degenerateScale() {
        #expect(HikingRoutesDrawing.zoom(for: 0) == 0)
        #expect(HikingRoutesDrawing.zoom(for: -1) == 0)
        #expect(HikingRoutesDrawing.zoom(for: .infinity) == 0)
        #expect(HikingRoutesDrawing.neededSquares(for: .world, zoomScale: 0).isEmpty)
    }

    @Test("a tile needs the squares of its level it overlaps, and none shallower than zoom 7")
    func neededSquares() {
        let tile = Self.tile(at: 14, latitude: 47.55, longitude: 12.98)
        let needed = HikingRoutesDrawing.neededSquares(for: tile, zoomScale: Self.zoomScale(14))
        #expect(needed == [RouteSquareGrid.square(at: .detail, latitude: 47.55, longitude: 12.98)])

        let shallow = Self.tile(at: 5, latitude: 47.55, longitude: 12.98)
        #expect(HikingRoutesDrawing.neededSquares(for: shallow, zoomScale: Self.zoomScale(5)).isEmpty)
    }

    @Test("a tile waits for its squares, asks for them, and is drawn once they are in")
    func waitsThenDraws() async throws {
        let square = RouteSquareGrid.square(at: .detail, latitude: 47.55, longitude: 12.98)
        let database = StubTrailCellDatabase(
            cells: [RouteSquareGrid.recordName(for: square): .found(Self.file.encoded())]
        )
        let squares = HikingRouteSquares(database: database, directory: nil)
        let renderer = HikingRoutesRenderer(overlay: HikingRoutesOverlay(squares: squares))
        let tile = Self.tile(at: 14, latitude: 47.55, longitude: 12.98)
        let scale = Self.zoomScale(14)

        #expect(!renderer.canDraw(tile, zoomScale: scale))
        await settleDelegateHop(until: "the square is in memory") { squares.holdsAll([square]) }
        #expect(database.requests.count == 1)
        #expect(renderer.canDraw(tile, zoomScale: scale))

        let image = try #require(Self.draw(tile, zoomScale: scale, with: renderer))
        let lineY = Int((MKMapPoint(CLLocationCoordinate2D(latitude: 47.55, longitude: 12.98)).y - tile.minY)
            / tile.height * Self.tileSide)
        let onLine = Self.pixel(in: image, x: Int(Self.tileSide / 4), y: lineY)
        #expect(onLine.blue > 200 && onLine.red < 100, "the line is drawn in the national routes' blue")
        #expect(onLine.alpha == 255)
        let offLine = Self.pixel(in: image, x: Int(Self.tileSide / 4), y: (lineY + 64) % Int(Self.tileSide))
        #expect(offLine.alpha == 0, "away from the line the tile stays clear")
    }

    /// Placed tile by tile, two neighbours could decide differently about a
    /// sign across their edge, and the map showed half of one.
    @Test("a sign across the edge of two tiles is drawn in both")
    func signAcrossTheEdge() async throws {
        // One short way, centred on the edge between two zoom-14 tiles, so
        // its one sign stands on the edge.
        let west = Self.tile(at: 14, latitude: 47.55, longitude: 12.98)
        let east = MKMapRect(x: west.maxX, y: west.minY, width: west.width, height: west.height)
        let edge = MKMapPoint(x: west.maxX, y: west.midY).coordinate
        let straddling = RouteSquareFile(
            routes: [RouteSquareFile.Route(id: 7, tags: ["network": "lwn", "ref": "7"])],
            lines: [
                RouteSquareFile.Line(
                    network: .local,
                    routes: [0],
                    points: [-0.001, 0.001].map { offset in
                        RouteSquareFile.Point(
                            latitude: Int32((edge.latitude * 1_000_000).rounded()),
                            longitude: Int32(((edge.longitude + offset) * 1_000_000).rounded())
                        )
                    }
                ),
            ],
            coordinateScale: 1_000_000
        )
        let square = RouteSquareGrid.square(at: .detail, latitude: edge.latitude, longitude: edge.longitude)
        let database = StubTrailCellDatabase(
            cells: [RouteSquareGrid.recordName(for: square): .found(straddling.encoded())]
        )
        let squares = HikingRouteSquares(database: database, directory: nil)
        let renderer = HikingRoutesRenderer(overlay: HikingRoutesOverlay(squares: squares))
        let scale = Self.zoomScale(14)
        // The east tile reaches into the next square, which has no record.
        await settleDelegateHop(until: "both tiles' squares are in memory") {
            renderer.canDraw(west, zoomScale: scale) && renderer.canDraw(east, zoomScale: scale)
        }

        let left = try #require(Self.draw(west, zoomScale: scale, with: renderer))
        let right = try #require(Self.draw(east, zoomScale: scale, with: renderer))
        // Five pixels above the line: inside the sign, clear of the line.
        let row = Int(Self.tileSide / 2) - 5
        let leftHalf = Self.pixel(in: left, x: Int(Self.tileSide) - 3, y: row)
        let rightHalf = Self.pixel(in: right, x: 3, y: row)
        #expect(leftHalf.alpha == 255, "the west tile draws its half of the sign")
        #expect(rightHalf.alpha == 255, "and the east tile the other half")
    }

    /// Draws `tile` the way MapKit would, into a bitmap one tile pixel a
    /// pixel.
    static func draw(
        _ tile: MKMapRect,
        zoomScale: MKZoomScale,
        with renderer: HikingRoutesRenderer
    ) -> CGImage? {
        let side = Int(tileSide)
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Top-left origin, as UIKit's and MapKit's drawing has it.
        context.translateBy(x: 0, y: tileSide)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: zoomScale, y: zoomScale)
        context.translateBy(x: -tile.minX, y: -tile.minY)
        renderer.draw(tile, zoomScale: zoomScale, in: context)
        return context.makeImage()
    }

    static func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, blue: UInt8, alpha: UInt8) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        let offset = y * image.bytesPerRow + x * 4
        return (bytes[offset], bytes[offset + 2], bytes[offset + 3])
    }
}
