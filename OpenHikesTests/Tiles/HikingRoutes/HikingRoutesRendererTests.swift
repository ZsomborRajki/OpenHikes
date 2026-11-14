//
//  HikingRoutesRendererTests.swift
//  OpenHikesTests
//
//  The hiking-routes layer drawn into a tile: which level and which squares a
//  tile at a zoom needs, nothing drawn before all of them are in, and a line
//  stroked in its network's colour where it runs.
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
    /// The tile side MapKit draws in, in points.
    private static let tileSide = 256.0

    /// The zoom scale MapKit draws zoom `zoom` at.
    private static func zoomScale(_ zoom: Int) -> MKZoomScale {
        MKZoomScale(pow(2, Double(zoom) - 20))
    }

    /// The tile at `zoom` holding a point, as MapKit names its ground.
    private static func tile(at zoom: Int, latitude: Double, longitude: Double) -> MKMapRect {
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
        #expect(HikingRoutesRenderer.level(for: Self.zoomScale(zoom)) == expected)
    }

    @Test("a tile needs the squares of its level it overlaps, and none shallower than zoom 7")
    func neededSquares() {
        let squares = HikingRouteSquares(database: StubTrailCellDatabase(), directory: nil)
        let renderer = HikingRoutesRenderer(overlay: HikingRoutesOverlay(squares: squares))
        let tile = Self.tile(at: 14, latitude: 47.55, longitude: 12.98)
        let needed = renderer.neededSquares(for: tile, zoomScale: Self.zoomScale(14))
        #expect(needed == [RouteSquareGrid.square(at: .detail, latitude: 47.55, longitude: 12.98)])

        let shallow = Self.tile(at: 5, latitude: 47.55, longitude: 12.98)
        #expect(renderer.neededSquares(for: shallow, zoomScale: Self.zoomScale(5)).isEmpty)
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
        let onLine = Self.pixel(in: image, x: Int(Self.tileSide / 2), y: lineY)
        let national = HikingRoutesRenderer.color(of: .national).components ?? []
        #expect(onLine.blue > onLine.red, "the line is drawn in the national routes' blue")
        #expect(abs(Double(onLine.blue) / 255 - Double(national[2])) < 0.1)
        let offLine = Self.pixel(in: image, x: Int(Self.tileSide / 2), y: (lineY + 64) % Int(Self.tileSide))
        #expect(offLine.alpha == 0, "away from the line the tile stays clear")
    }

    /// Draws `tile` the way MapKit would, into a bitmap one point a pixel.
    private static func draw(
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

    private static func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, blue: UInt8, alpha: UInt8) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        let offset = y * image.bytesPerRow + x * 4
        return (bytes[offset], bytes[offset + 2], bytes[offset + 3])
    }
}
