//
//  LibraryLinesRendererTests.swift
//  OpenHikesTests
//
//  The library's lines, drawn into a bitmap the way MapKit hands a renderer a
//  tile: the map already in it, painted opaque grey first — see
//  `DirectionalPolylineRendererTests+Basemap.swift` for why an empty canvas
//  cannot show what a draw does to the map.
//
//  The overlay is the world, so its renderer draws in map points from the
//  world's corner; the canvas is moved to the tile's corner first, which is
//  what MapKit's own transform does. At a zoom scale of one a map point is a
//  pixel, and the lines here are wide enough that a line, its outline and the
//  map beside it are whole pixels apart.
//

import CoreGraphics
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Library lines rendering")
struct LibraryLinesRendererTests {
    private typealias Canvas = DirectionalPolylineRendererTests.Canvas

    private static let side = 256
    /// Where the tile drawn starts, in map points.
    private static let tile = MKMapRect(x: 1_000_000, y: 1_000_000, width: Double(side), height: Double(side))
    /// Twelve points of line, and an outline of four either side of it.
    private static let lineWidth: CGFloat = 12
    private static let layerAlpha: CGFloat = 0.6
    /// How far from a line's middle its outline is drawn, and how far the map
    /// is left alone.
    private static let ringOffset = 8
    private static let clearOffset = 40
    /// How far two colours composited through a layer may land from the
    /// arithmetic, in levels of eight bits.
    private static let tolerance = 3

    private static let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private static let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    private static let basemap = CGColor(gray: 0.5, alpha: 1)

    /// A line across the whole tile, `offset` map points from its edge.
    private static func across(at offset: Int) -> MKPolyline {
        var points = [
            MKMapPoint(x: tile.minX - 50, y: tile.minY + Double(offset)),
            MKMapPoint(x: tile.maxX + 50, y: tile.minY + Double(offset)),
        ]
        return MKPolyline(points: &points, count: points.count)
    }

    /// The same, down the tile.
    private static func down(at offset: Int) -> MKPolyline {
        var points = [
            MKMapPoint(x: tile.minX + Double(offset), y: tile.minY - 50),
            MKMapPoint(x: tile.minX + Double(offset), y: tile.maxY + 50),
        ]
        return MKPolyline(points: &points, count: points.count)
    }

    private static func line(_ polyline: MKPolyline, _ color: CGColor) -> LibraryLinesRenderer.Line {
        LibraryLinesRenderer.Line(polylines: [polyline], boundingMapRect: polyline.boundingMapRect, color: color)
    }

    /// `lines`, in the order given, drawn over the map into `tile`.
    private static func render(_ lines: [LibraryLinesRenderer.Line]) throws -> Canvas {
        let renderer = LibraryLinesRenderer(
            overlay: LibraryLinesOverlay(),
            layerAlpha: layerAlpha,
            lineWidth: lineWidth,
            borderColor: black
        )
        renderer.setLines(lines)
        let canvas = try Canvas(side: side)
        canvas.context.setFillColor(basemap)
        canvas.context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        canvas.context.translateBy(x: -tile.minX, y: -tile.minY)
        renderer.draw(tile, zoomScale: 1, in: canvas.context)
        return canvas
    }

    /// The bitmap's rows run the other way from the map's.
    private static func pixel(_ canvas: Canvas, x: Int, y: Int) -> [Int] {
        canvas.pixel(x: x, row: side - 1 - y).map(Int.init)
    }

    /// `color` as a canvas like these holds it: converted into the canvas's
    /// colour space, which is not the one a `CGColor` is made in.
    private static func drawn(_ color: CGColor) throws -> [Int] {
        let swatch = try Canvas(side: 1)
        swatch.context.setFillColor(color)
        swatch.context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return swatch.pixel(x: 0, row: 0).map(Int.init)
    }

    /// `color` laid over the map's grey at the layer's strength.
    private static func expected(_ color: CGColor, over map: [Int]) throws -> [Int] {
        zip(try drawn(color), map).map { channel, under in
            Int((Double(layerAlpha) * Double(channel) + (1 - Double(layerAlpha)) * Double(under)).rounded())
        }
    }

    private static func isNear(_ pixel: [Int], _ expected: [Int]) -> Bool {
        zip(pixel.prefix(3), expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test("a line is laid over the map faded, outlined in black faded with it")
    func aLineIsFadedAndOutlined() throws {
        let canvas = try Self.render([Self.line(Self.across(at: 128), Self.red)])
        let map = Self.pixel(canvas, x: 100, y: 128 + Self.clearOffset)

        let middle = Self.pixel(canvas, x: 100, y: 128)
        #expect(Self.isNear(middle, try Self.expected(Self.red, over: map)), "\(middle)")
        let ring = Self.pixel(canvas, x: 100, y: 128 + Self.ringOffset)
        #expect(Self.isNear(ring, try Self.expected(Self.black, over: map)), "\(ring)")
        #expect(middle[3] == 255 && ring[3] == 255, "the map is still under the line")
        #expect(Self.isNear(Self.pixel(canvas, x: 100, y: 0), map), "the map away from the line is untouched")
    }

    /// The loop behind the house, walked forty times, is one faded line —
    /// not forty laid on one another until it is solid.
    @Test("hikes over one trail read as one line")
    func overlappingHikesReadAsOne() throws {
        let once = try Self.render([Self.line(Self.across(at: 128), Self.red)])
        let often = try Self.render((0..<5).map { _ in Self.line(Self.across(at: 128), Self.red) })
        #expect(Self.isNear(Self.pixel(often, x: 100, y: 128), Self.pixel(once, x: 100, y: 128)))
        #expect(Self.isNear(
            Self.pixel(often, x: 100, y: 128 + Self.ringOffset),
            Self.pixel(once, x: 100, y: 128 + Self.ringOffset)
        ))
    }

    /// The coordinator hands the lines over oldest first, so the newest hike
    /// is the one drawn where two cross.
    @Test("the line given last is drawn on top")
    func theLastLineIsOnTop() throws {
        let redLine = Self.line(Self.across(at: 128), Self.red)
        let blueLine = Self.line(Self.down(at: 128), Self.blue)
        let redLast = try Self.render([blueLine, redLine])
        let blueLast = try Self.render([redLine, blueLine])
        let map = Self.pixel(redLast, x: 0, y: 0)
        #expect(Self.isNear(Self.pixel(redLast, x: 128, y: 128), try Self.expected(Self.red, over: map)))
        #expect(Self.isNear(Self.pixel(blueLast, x: 128, y: 128), try Self.expected(Self.blue, over: map)))
    }

    /// Every outline first, every line over them: two trails side by side
    /// are two lines touching, not one line cut by the other's outline.
    @Test("no outline is drawn over a line")
    func outlinesAreUnderLines() throws {
        // Fourteen points apart, so each outline reaches into the other line.
        let canvas = try Self.render([
            Self.line(Self.across(at: 134), Self.blue),
            Self.line(Self.across(at: 120), Self.red),
        ])
        let map = Self.pixel(canvas, x: 0, y: 0)
        // Inside the red line, where the blue one's outline reaches.
        #expect(Self.isNear(Self.pixel(canvas, x: 100, y: 125), try Self.expected(Self.red, over: map)))
        // And the other way round.
        #expect(Self.isNear(Self.pixel(canvas, x: 100, y: 129), try Self.expected(Self.blue, over: map)))
    }

    @Test("a tile no line crosses is left as it was")
    func aTileWithNoLineIsUntouched() throws {
        let far = try Self.render([Self.line(Self.across(at: 10_000), Self.red)])
        let map = Self.pixel(far, x: 0, y: 0)
        for y in stride(from: 0, to: Self.side, by: 16) {
            #expect(Self.isNear(Self.pixel(far, x: 128, y: y), map))
        }
    }
}
