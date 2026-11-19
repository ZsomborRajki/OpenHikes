//
//  VectorTileArrowsTests.swift
//  OpenHikesTests
//
//  The one-way arrows on a drawn tile, read from tiles written by
//  `VectorTileFixture`: which lines carry them and which way they point,
//  where Carto's two placements put them along a line, and that an arrow is
//  never cut at a tile's edge or drawn over a name.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
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

    /// Budapest's Szent István tér is tagged `oneway=yes` and drawn the way
    /// it runs; a way tagged `-1` runs against its drawing.
    @Test("a one-way line runs as drawn for yes, against it for -1, and a line not one-way has none")
    func direction() throws {
        let lines = try oneWay([
            road(oneway: "yes", y: grid / 4),
            road(oneway: "-1", y: grid / 2),
            road(oneway: "no", y: grid * 3 / 4),
            road(oneway: nil, y: grid * 7 / 8),
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
        let decoded = try VectorTileFixture.decoded([roads([road(oneway: "yes", y: grid / 2)])])

        #expect(VectorTileArrows.lines(in: decoded, source: wide, target: wide).isEmpty)
    }

    @Test(
        "each kind of street and path is read from the archive's kinds, and a pier or a railway is none",
        arguments: [
            ("highway", "motorway", VectorTileArrows.Kind.motorway),
            ("major_road", "trunk_link", .trunk),
            ("major_road", "tertiary", .tertiary),
            ("minor_road", "service", .minorRoad),
            ("other", "living_street", .livingStreet),
            ("path", "pedestrian", .pedestrian),
            ("path", "steps", .footway),
            ("path", "cycleway", .cycleway),
            ("path", "pier", nil),
            ("rail", "tram", nil),
            ("other", "busway", nil),
        ] as [(String, String, VectorTileArrows.Kind?)]
    )
    func kinds(kind: String, detail: String, expected: VectorTileArrows.Kind?) {
        #expect(VectorTileArrows.Kind(kind: kind, detail: detail) == expected)
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

    @Test("pieces that meet end to start are joined, and two that meet head to head stay apart")
    func joining() {
        let first = [CGPoint.zero, CGPoint(x: 10, y: 0)]
        let second = [CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0)]
        let headToHead = [CGPoint(x: 30, y: 0), CGPoint(x: 20, y: 0)]

        let joined = VectorTileArrows.joined([second, headToHead, first])

        #expect(joined.count == 2)
        #expect(joined.contains([.zero, CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0)]))
        #expect(joined.contains(headToHead))
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

    @Test("an arrow points the way its line is travelled")
    func arrowsPointAlongTheirLine() throws {
        let layout = try layout([road(oneway: "yes", y: grid / 4), road(oneway: "-1", y: grid / 2)])

        let along = layout.placements.filter { $0.center.y.isApproximatelyEqual(to: side / 4, absoluteTolerance: 1) }
        let against = layout.placements.filter { $0.center.y.isApproximatelyEqual(to: side / 2, absoluteTolerance: 1) }
        #expect(!along.isEmpty && !against.isEmpty)
        #expect(along.allSatisfy { $0.angle.isApproximatelyEqual(to: 0, absoluteTolerance: 0.01) })
        #expect(against.allSatisfy { abs($0.angle).isApproximatelyEqual(to: .pi, absoluteTolerance: 0.01) })
    }

    /// The next tile could not finish an arrow cut at the edge, so one is
    /// drawn wholly inside a tile or not at all.
    @Test("no arrow is cut at the tile's edge")
    func noArrowCrossesTheEdge() throws {
        // A street from just outside the tile's left edge, whose first mark
        // falls on the edge itself.
        let start = -Int(VectorTileArrows.spacing / 2 * CGFloat(grid) / VectorTileRasterizer.styleTileSize)
        let street = road(oneway: "yes", y: grid / 2, from: start)

        let layout = try layout([street])

        #expect(!layout.placements.isEmpty)
        #expect(layout.placements.allSatisfy { bounds.contains($0.frame) })
    }

    /// Carto places the streets' names before their arrows, so an arrow
    /// moves along its street to stand clear of a name.
    @Test("an arrow slides along its line to stand clear of a name")
    func arrowsKeepClearOfNames() throws {
        let decoded = try VectorTileFixture.decoded([roads([road(oneway: "yes", y: grid / 2)])])
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
        let oneWay = [land, roads([road(oneway: "yes", y: grid / 2)])]
        let twoWay = [land, roads([road(oneway: "no", y: grid / 2)])]
        let wide = VectorTileAddress(z: 15, x: 17_600, y: 11_400)

        let drawn = try #require(try VectorTileFixture.image(oneWay, from: tile, drawing: tile))
        let plain = try #require(try VectorTileFixture.image(twoWay, from: tile, drawing: tile))
        let wider = try #require(try VectorTileFixture.image(oneWay, from: wide, drawing: wide))

        #expect(VectorTileFixture.image(drawn, has: "#555555"))
        #expect(!VectorTileFixture.image(plain, has: "#555555"))
        #expect(!VectorTileFixture.image(wider, has: "#555555"), "and none before zoom 16")
    }

    // MARK: Helpers

    /// A residential street across the tile at `y`, from `start` to a
    /// quarter of the tile past its right edge.
    private func road(oneway: String?, y: Int, from start: Int = 0) -> VectorTileFixture.Feature {
        var properties: [String: VectorTileFixture.Value] = [
            "kind": .string("minor_road"), "kind_detail": .string("residential"),
        ]
        if let oneway { properties["oneway"] = .string(oneway) }
        let end = start == 0 ? grid : grid + grid / 4
        return .init(type: .line, properties: properties, geometry: VectorTileFixture.line([(start, y), (end, y)]))
    }

    private func roads(_ features: [VectorTileFixture.Feature]) -> VectorTileFixture.Layer {
        .init(name: "roads", features: features)
    }

    private func oneWay(_ features: [VectorTileFixture.Feature]) throws -> [VectorTileArrows.OneWayLine] {
        let decoded = try VectorTileFixture.decoded([roads(features)])
        return VectorTileArrows.lines(in: decoded, source: tile, target: tile)
    }

    private func layout(_ features: [VectorTileFixture.Feature]) throws -> VectorTileArrows.Layout {
        var room = VectorTilePoints.Room(bounds: bounds, taken: [])
        return VectorTileArrows.Layout(try oneWay(features), unit: unit, room: &room)
    }
}
