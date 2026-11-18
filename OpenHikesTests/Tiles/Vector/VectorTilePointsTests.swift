//
//  VectorTilePointsTests.swift
//  OpenHikesTests
//
//  The points on a drawn tile, read from tiles written by `VectorTileFixture`
//  against a small table of their own, with icons that are squares of their
//  fill: which points are chosen and in what order, where their icons and
//  names stand, and how a long name breaks.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile points")
struct VectorTilePointsTests {
    private let tile = VectorTileAddress(z: 17, x: 72_491, y: 45_826)
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }
    private let unit: CGFloat = 2

    // MARK: Choosing

    @Test("a point is chosen with its name, and a summit's height under it; a kind the table has not is left out")
    func whatIsChosen() throws {
        let points = try candidates([
            poi(["kind": .string("fuel"), "name": .string("MOL")], at: (grid / 4, grid / 4)),
            poi(["kind": .string("peak"), "name": .string("Kogel"), "elevation": .double(1200)]),
            poi(["kind": .string("tattoo_parlour"), "name": .string("Ink")], at: (grid * 3 / 4, grid / 4)),
        ])

        #expect(points.map(\.lines) == [["Kogel", "1200 m"], ["MOL"]])
    }

    @Test("the higher summit claims room first, as Carto orders them")
    func higherSummitFirst() throws {
        let points = try candidates([
            poi(["kind": .string("peak"), "name": .string("Low"), "elevation": .double(900)]),
            poi(["kind": .string("peak"), "name": .string("High"), "elevation": .double(2100)], at: (100, 100)),
        ])

        #expect(points.map(\.lines.first) == ["High", "Low"])
    }

    // MARK: Placing

    @Test("an icon stands on its point, and a second icon on the same spot is left out")
    func iconsDoNotOverlap() throws {
        let points = try candidates([
            poi(["kind": .string("fuel"), "name": .string("MOL")]),
            poi(["kind": .string("fuel"), "name": .string("OMV")], at: (grid / 2 + 20, grid / 2)),
        ])
        var room = VectorTilePoints.Room(bounds: bounds, taken: [])

        let icons = VectorTilePoints.Icons(points, unit: unit, room: &room)

        #expect(icons.count == 1)
        let frame = try #require(icons.frames.first)
        #expect(frame.midX == side / 2 && frame.midY == side / 2)
        #expect(frame.width == 14 * unit)
    }

    /// A point belongs to the tile it lies in, so its icon is moved in from
    /// the edge rather than cut by it.
    @Test("an icon near the tile's edge is moved inside it")
    func iconMovesInsideTheEdge() throws {
        let points = try candidates([poi(["kind": .string("fuel")], at: (2, grid / 2))])
        var room = VectorTilePoints.Room(bounds: bounds, taken: [])

        let icons = VectorTilePoints.Icons(points, unit: unit, room: &room)

        let frame = try #require(icons.frames.first)
        #expect(frame.minX == 0)
    }

    @Test("a point's name stands under its icon")
    func nameUnderIcon() throws {
        let points = try candidates([poi(["kind": .string("fuel"), "name": .string("MOL")])])
        var room = VectorTilePoints.Room(bounds: bounds, taken: [])
        var fonts = LabelFonts(language: "en")

        let icons = VectorTilePoints.Icons(points, unit: unit, room: &room)
        let names = VectorTilePoints.Names(points, unit: unit, room: &room, fonts: &fonts)

        let icon = try #require(icons.frames.first)
        let name = try #require(names.frames.first)
        #expect(name.minY > icon.midY)
        #expect(abs(name.midX - icon.midX) < 1)
    }

    @Test("a bench waits for every other point, and finds no room where one stands")
    func lowPriorityComesLast() throws {
        let points = try candidates([
            poi(["kind": .string("bench")]),
            poi(["kind": .string("fuel")], at: (grid / 2 + 10, grid / 2)),
        ])
        var room = VectorTilePoints.Room(bounds: bounds, taken: [])

        let main = VectorTilePoints.Icons(points.filter { !$0.look.lowPriority }, unit: unit, room: &room)
        let low = VectorTilePoints.Icons(points.filter(\.look.lowPriority), unit: unit, room: &room)

        #expect(main.count == 1)
        #expect(low.count == 0)
    }

    /// Mapnik ends a line once it is wider than the wrap width, after the
    /// word that made it so, which is how openstreetmap.org sets a school's
    /// name over four lines: "Arany János / Általános / Iskola és / Alapfokú".
    @Test("a long name breaks between words as Mapnik breaks it")
    func wrapping() {
        let measure = { (text: String) in CGFloat(text.count) }

        #expect(VectorTilePoints.wrapped("Arany János Általános Iskola és Alapfokú", width: 6, measure: measure) == [
            "Arany János", "Általános", "Iskola és", "Alapfokú",
        ])
        #expect(VectorTilePoints.wrapped("Művészetoktatási", width: 6, measure: measure) == ["Művészetoktatási"])
        #expect(VectorTilePoints.wrapped("Two words", width: 0, measure: measure) == ["Two words"])
    }

    // MARK: Drawing

    @Test("a point's icon is drawn on the map, in its fill")
    func iconIsDrawn() throws {
        let fuel = poi(["kind": .string("fuel")])
        let decoded = try VectorTileFixture.decoded([land, .init(name: "pois", features: [fuel])])

        let image = try #require(VectorTileRasterizer.image(
            of: decoded,
            from: tile,
            drawing: tile,
            language: "en",
            height: VectorTileFixture.height,
            points: VectorTilePointSet(style: try Self.style(), icons: SquareIcons())
        ))

        #expect(pixel(image, x: Int(side / 2), y: Int(side / 2)) == [0xFF, 0, 0])
    }

    // MARK: Helpers

    /// Three kinds, as `Scripts/carto-points.sh` writes them: fuel with a
    /// name under it, a summit with its height, and a low-priority bench.
    private static func style() throws -> VectorTilePointStyle {
        let name = """
        {"field": "name", "size": 10, "fill": "#0066FF", "halo": "#FFFFFF99", "haloRadius": 1, "dy": 11,
        "wrapWidth": 30, "lineSpacing": -1.5, "face": "regular"}
        """
        let fuel = """
        {"kind": "fuel", "feature": "amenity_fuel", "lowPriority": false, "bands": [{"from": 15, "to": 19,
        "icons": [{"asset": "pump", "fill": "#FF0000", "width": 14, "height": 14}], "text": \(name)}]}
        """
        let peak = """
        {"kind": "peak", "feature": "natural_peak", "lowPriority": false, "elevation": true, "bands": [
        {"from": 15, "to": 19, "icons": [{"asset": "peak", "fill": "#D08F55", "width": 8, "height": 8}],
        "text": \(name)}]}
        """
        let bench = """
        {"kind": "bench", "feature": "amenity_bench", "lowPriority": true, "bands": [{"from": 15, "to": 19,
        "icons": [{"asset": "bench", "fill": "#666666", "width": 14, "height": 14}]}]}
        """
        let entries = [fuel, peak, bench].joined(separator: ",")
        let json = #"{"source": "openstreetmap-carto test", "entries": ["# + entries + "]}"
        return try VectorTilePointStyle(json: Data(json.utf8))
    }

    /// Icons that are squares of their fill.
    private struct SquareIcons: VectorTileIconDrawing {
        func image(asset: String, fill: CGColor?, size: CGSize) -> CGImage? {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil,
                      width: Int(size.width),
                      height: Int(size.height),
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return nil }
            context.setFillColor(fill ?? VectorTileStyle.color("#000000"))
            context.fill(CGRect(origin: .zero, size: size))
            return context.makeImage()
        }
    }

    private var land: VectorTileFixture.Layer {
        .init(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
    }

    private func poi(
        _ properties: [String: VectorTileFixture.Value],
        at position: (Int, Int)? = nil
    ) -> VectorTileFixture.Feature {
        let spot = position ?? (grid / 2, grid / 2)
        return .init(type: .point, properties: properties, geometry: VectorTileFixture.points([spot]))
    }

    private func candidates(_ features: [VectorTileFixture.Feature]) throws -> [VectorTilePoints.Candidate] {
        let decoded = try VectorTileFixture.decoded([.init(name: "pois", features: features)])
        return VectorTilePoints.candidates(
            in: decoded,
            source: tile,
            target: tile,
            language: "en",
            height: VectorTileFixture.height,
            style: try Self.style()
        )
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let width = image.width
        var bytes = [UInt8](repeating: 0, count: width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        let index = (y * width + x) * 4
        return [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
    }
}
