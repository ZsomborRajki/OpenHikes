//
//  VectorTileArrowsTests.swift
//  OpenHikesVectorTilesTests
//
//  The one-way arrows on a drawn tile, read from tiles written by
//  `VectorTileFixture`: which ways carry them and which way they point,
//  where Carto's two placements put them along a way, and that an arrow is
//  never cut at a tile's edge or drawn over a name.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
import RealModule
import Testing

@Suite("Vector tile one-way arrows")
struct VectorTileArrowsTests {
    private let tile = VectorTileAddress(z: 16, x: 35_200, y: 22_800)
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }
    private let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize

    // MARK: Choosing

    /// The extras keep each way's nodes in OpenStreetMap's order, which is
    /// the way it is travelled for `yes` and against it for `-1`.
    @Test("a one-way way runs as drawn for yes, against it for -1, and a way not one-way has none")
    func direction() throws {
        let lines = try oneWay([
            way(oneway: "yes", y: grid / 4),
            way(oneway: "-1", y: grid / 2),
            way(oneway: "no", y: grid * 3 / 4),
            way(oneway: nil, y: grid * 7 / 8),
        ])

        #expect(lines.count == 2)
        let along = try #require(lines.first { $0.points.first?.y == side / 4 })
        let against = try #require(lines.first { $0.points.first?.y == side / 2 })
        #expect(along.points.first?.x == 0)
        #expect(against.points.first?.x == side)
    }

    @Test("Carto draws no arrows before zoom 16")
    func notBeforeZoom16() throws {
        let wide = VectorTileAddress(z: 15, x: 17_600, y: 11_400)
        let decoded = try VectorTileFixture.decoded([oneways([way(oneway: "yes", y: grid / 2)])])

        #expect(VectorTileArrows.lines(in: decoded, source: wide, target: wide).isEmpty)
    }

    /// The basemap's build merges a road's pieces and can turn one around,
    /// so its `oneway` is never drawn: Király utca's arrows pointed back.
    @Test("the basemap's roads carry no arrows, one-way or not")
    func notFromTheBasemap() throws {
        let road = VectorTileFixture.Feature(
            type: .line,
            properties: [
                "kind": .string("minor_road"), "kind_detail": .string("residential"), "oneway": .string("yes"),
            ],
            geometry: VectorTileFixture.line([(0, grid / 2), (grid, grid / 2)])
        )
        let decoded = try VectorTileFixture.decoded([.init(name: "roads", features: [road])])

        #expect(VectorTileArrows.lines(in: decoded, source: tile, target: tile).isEmpty)
    }

    @Test(
        "each street and path is read by its highway, a link as its road, and a raceway or a platform is none",
        arguments: [
            ("motorway", VectorTileArrows.Kind.motorway),
            ("trunk_link", .trunk),
            ("tertiary", .tertiary),
            ("service", .minorRoad),
            ("living_street", .livingStreet),
            ("pedestrian", .pedestrian),
            ("steps", .footway),
            ("cycleway", .cycleway),
            ("raceway", nil),
            ("platform", nil),
            ("construction", nil),
        ] as [(String, VectorTileArrows.Kind?)]
    )
    func kinds(highway: String, expected: VectorTileArrows.Kind?) {
        #expect(VectorTileArrows.Kind(highway: highway) == expected)
    }

    /// The extras' build keeps only the highways the arrows read, listed
    /// once under `&arrowed`.
    @Test("the extras keep exactly the highways the arrows are drawn along")
    func extrasKeepTheArrowedHighways() throws {
        let schema = try String(
            contentsOf: Checkout.extrasSchema,
            encoding: .utf8
        )
        let line = try #require(schema.split(separator: "\n").first { $0.contains("&arrowed [") })
        let list = try #require(line.split(separator: "[").last?.split(separator: "]").first)
        let highways = Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

        #expect(highways == Set(VectorTileArrows.Kind.byHighway.keys))
    }

    @Test(
        "a street takes Carto's marker, a pedestrian street among them, and a path its text",
        arguments: [
            (VectorTileArrows.Kind.motorway, VectorTileArrows.Arrow.Style.marker),
            (.minorRoad, .marker),
            (.pedestrian, .marker),
            (.footway, .text),
            (.bridleway, .text),
        ]
    )
    func styles(kind: VectorTileArrows.Kind, style: VectorTileArrows.Arrow.Style) {
        #expect(kind.arrow.style == style)
    }

    // MARK: Placing

    /// Mapnik places a marker half a spacing from the start and every
    /// spacing after, so a street shorter than half a spacing has none.
    @Test("a street's arrows stand half a spacing in and a spacing apart, and a short street has none")
    func markerMarks() {
        let marks = VectorTileArrows.marks(.marker, length: 400, width: 12, spacing: 180, step: 3)
        let short = VectorTileArrows.marks(.marker, length: 80, width: 12, spacing: 180, step: 3)

        #expect(marks.map(\.distance) == [90, 270])
        #expect(marks.allSatisfy { $0.spots.first == $0.distance })
        #expect(marks.flatMap(\.spots).allSatisfy { (6...394).contains($0) }, "the whole arrow lies on the line")
        #expect(marks.first?.spots.max() == 180, "a marker slides up to half a spacing")
        #expect(short.isEmpty)
    }

    /// Mapnik places a line's text as many times as fits a spacing apart,
    /// spread evenly, so a path the arrow fits on has one.
    @Test("a path's arrows are spread evenly over it, and a short path has one in its middle")
    func textMarks() {
        let marks = VectorTileArrows.marks(.text, length: 400, width: 12, spacing: 180, step: 3)
        let short = VectorTileArrows.marks(.text, length: 60, width: 12, spacing: 180, step: 3)
        let tooShort = VectorTileArrows.marks(.text, length: 10, width: 12, spacing: 180, step: 3)

        #expect(marks.map(\.distance) == [100, 300])
        #expect(short.map(\.distance) == [30])
        #expect(tooShort.isEmpty)
    }

    /// Mapnik spaces each of Carto's lines on its own, so two streets that
    /// meet are not one line: a 120-pixel and a 105-pixel street each have
    /// room for an arrow, and joined end to start they would have one.
    @Test("each way is spaced on its own, where it meets another")
    func waysAreSpacedApart() throws {
        let pixel = grid / Int(VectorTileRasterizer.styleTileSize)
        let corner = (32 + 120) * pixel
        let across = VectorTileFixture.Feature(
            type: .line,
            properties: ["kind": .string("residential"), "oneway": .string("yes")],
            geometry: VectorTileFixture.line([(32 * pixel, 64 * pixel), (corner, 64 * pixel)])
        )
        let down = VectorTileFixture.Feature(
            type: .line,
            properties: ["kind": .string("residential"), "oneway": .string("yes")],
            geometry: VectorTileFixture.line([(corner, 64 * pixel), (corner, (64 + 105) * pixel)])
        )

        let layout = try laidOut([across, down])

        #expect(layout.placements.count == 2)
        #expect(layout.placements.contains { $0.center.y.isApproximatelyEqual(to: 64 * unit, absoluteTolerance: 1) })
        #expect(layout.placements.contains { $0.center.x.isApproximatelyEqual(to: 152 * unit, absoluteTolerance: 1) })
    }

    @Test("an arrow points the way its line is travelled")
    func arrowsPointAlongTheirLine() throws {
        let layout = try laidOut([way(oneway: "yes", y: grid / 4), way(oneway: "-1", y: grid / 2)])

        let along = layout.placements.filter { $0.center.y.isApproximatelyEqual(to: side / 4, absoluteTolerance: 1) }
        let against = layout.placements.filter { $0.center.y.isApproximatelyEqual(to: side / 2, absoluteTolerance: 1) }
        #expect(!along.isEmpty && !against.isEmpty)
        #expect(along.allSatisfy { $0.angle.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01) })
        #expect(against.allSatisfy { abs($0.angle).isApproximatelyEqual(to: .pi, absoluteTolerance: 0.01) })
    }

    /// Mapnik turns a marker to the segment under it. Here the line between
    /// the arrow's ends runs east, across a jog whose middle runs west.
    @Test("a street's arrow turns to the segment under its middle")
    func markerTurnsToItsSegment() {
        let jog = MeasuredPath([
            CGPoint(x: 20, y: 100), CGPoint(x: 196, y: 100), CGPoint(x: 196, y: 101),
            CGPoint(x: 190, y: 101), CGPoint(x: 190, y: 102), CGPoint(x: 400, y: 102),
        ])

        let street = VectorTileArrows.Kind.minorRoad.arrow
        let path = VectorTileArrows.Kind.footway.arrow

        let marker = VectorTileArrows.Placement(arrow: street, along: jog, at: 180, unit: 2)
        let text = VectorTileArrows.Placement(arrow: path, along: jog, at: 180, unit: 2)

        #expect(marker.center == CGPoint(x: 193, y: 101))
        #expect(abs(marker.angle).isApproximatelyEqual(to: .pi, absoluteTolerance: 0.01))
        #expect(abs(text.angle) < .pi / 2, "a path's arrow follows the line between its ends, as Mapnik's text does")
    }

    /// The next tile could not finish an arrow cut at the edge, so one is
    /// drawn wholly inside a tile or not at all.
    @Test("no arrow is cut at the tile's edge")
    func noArrowCrossesTheEdge() throws {
        // A street from just outside the tile's left edge, whose first mark
        // falls on the edge itself.
        let start = -Int(VectorTileArrows.spacing / 2 * CGFloat(grid) / VectorTileRasterizer.styleTileSize)
        let street = way(oneway: "yes", y: grid / 2, from: start)

        let layout = try laidOut([street])

        #expect(!layout.placements.isEmpty)
        #expect(layout.placements.allSatisfy { bounds.contains($0.frame) })
    }

    /// Carto places the streets' names before their arrows, so an arrow
    /// moves along its street to stand clear of a name.
    @Test("an arrow slides along its line to stand clear of a name")
    func arrowsKeepClearOfNames() throws {
        let decoded = try VectorTileFixture.decoded([oneways([way(oneway: "yes", y: grid / 2)])])
        let lines = VectorTileArrows.lines(in: decoded, source: tile, target: tile)
        let firstMark = VectorTileArrows.spacing / 2 * unit
        let name = CGRect(x: firstMark - 20, y: side / 2 - 10, width: 40, height: 20)
        var room = VectorTilePoints.Room(bounds: bounds, taken: [name])

        let layout = VectorTileArrows.Layout(lines, unit: unit, room: &room)

        let first = try #require(layout.placements.first)
        #expect(!first.frame.intersects(name))
        #expect(abs(first.center.x - firstMark) <= VectorTileArrows.spacing / 2 * unit)
    }

    @Test("a one-way street is drawn with its arrows in Carto's ink, and a two-way one without")
    func arrowsAreDrawn() throws {
        let land = VectorTileFixture.Layer(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
        let oneWay = [land, oneways([way(oneway: "yes", y: grid / 2)])]
        let twoWay = [land, oneways([way(oneway: "no", y: grid / 2)])]
        let wide = VectorTileAddress(z: 15, x: 17_600, y: 11_400)

        let drawn = try #require(try VectorTileFixture.image(oneWay, from: tile, drawing: tile))
        let plain = try #require(try VectorTileFixture.image(twoWay, from: tile, drawing: tile))
        let wider = try #require(try VectorTileFixture.image(oneWay, from: wide, drawing: wide))

        #expect(VectorTileFixture.image(drawn, has: "#555555"))
        #expect(!VectorTileFixture.image(plain, has: "#555555"))
        #expect(!VectorTileFixture.image(wider, has: "#555555"), "and none before zoom 16")
    }

    // MARK: Helpers

    /// A residential street across the tile at `y`, as the extras keep it:
    /// from `start` to the tile's right edge, or to a quarter of the tile
    /// past it for a street that starts elsewhere.
    private func way(oneway: String?, y: Int, from start: Int = 0) -> VectorTileFixture.Feature {
        var properties: [String: VectorTileFixture.Value] = ["kind": .string("residential")]
        if let oneway { properties["oneway"] = .string(oneway) }
        let end = start == 0 ? grid : grid + grid / 4
        return .init(type: .line, properties: properties, geometry: VectorTileFixture.line([(start, y), (end, y)]))
    }

    private func oneways(_ features: [VectorTileFixture.Feature]) -> VectorTileFixture.Layer {
        .init(name: VectorTileArrows.layerName, features: features)
    }

    private func oneWay(_ features: [VectorTileFixture.Feature]) throws -> [VectorTileArrows.OneWayLine] {
        let decoded = try VectorTileFixture.decoded([oneways(features)])
        return VectorTileArrows.lines(in: decoded, source: tile, target: tile)
    }

    private func laidOut(_ features: [VectorTileFixture.Feature]) throws -> VectorTileArrows.Layout {
        var room = VectorTilePoints.Room(bounds: bounds, taken: [])
        return VectorTileArrows.Layout(try oneWay(features), unit: unit, room: &room)
    }
}
