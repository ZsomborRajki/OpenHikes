//
//  VectorTileShieldsTests.swift
//  OpenHikesTests
//
//  The numbers of roads: which roads get a plate and from which zoom, what a
//  `ref` holds, where a road crosses the world's grid, and that two tiles
//  holding one road agree on its plates without seeing each other's.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile road numbers")
struct VectorTileShieldsTests {
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize
    private let grid = VectorTileFixture.grid

    private var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    @Test("a motorway, a trunk, a primary, a secondary and a tertiary road get a plate; a link and a street none")
    func roadsWithPlates() {
        typealias Road = VectorTileShields.Road
        #expect(Road.road(kind: "highway", detail: "motorway") == .motorway)
        #expect(Road.road(kind: "major_road", detail: "trunk") == .trunk)
        #expect(Road.road(kind: "major_road", detail: "primary") == .primary)
        #expect(Road.road(kind: "major_road", detail: "secondary") == .secondary)
        #expect(Road.road(kind: "major_road", detail: "tertiary") == .tertiary)
        #expect(Road.road(kind: "highway", detail: "motorway_link") == nil)
        #expect(Road.road(kind: "major_road", detail: "primary_link") == nil)
        #expect(Road.road(kind: "minor_road", detail: "residential") == nil)
        #expect(Road.road(kind: "path", detail: "footway") == nil)
    }

    @Test("each road's number comes in at Carto's zoom for it")
    func firstZooms() {
        #expect(VectorTileShields.Road.allCases.sorted().map(\.firstZ) == [10, 11, 11, 12, 13])
    }

    @Test("a ref's numbers are split at its semicolons, and one Carto has no plate for gives none")
    func numbersInARef() {
        #expect(VectorTileShields.numbers(in: "A 3") == ["A 3"])
        #expect(VectorTileShields.numbers(in: "A 3;E 42") == ["A 3", "E 42"])
        #expect(VectorTileShields.numbers(in: " B 43 ; ") == ["B 43"])
        #expect(VectorTileShields.numbers(in: "").isEmpty)
        #expect(VectorTileShields.numbers(in: "1;2;3;4;5").isEmpty, "more lines than the tallest plate has")
        #expect(VectorTileShields.numbers(in: "A very long number").isEmpty, "wider than the widest plate")
    }

    @Test("a line's crossings are where it meets the grid's lines, across and down")
    func crossingsOfTheGrid() {
        let line = [CGPoint(x: 10, y: 50), CGPoint(x: 250, y: 50)]

        let crossings = VectorTileShields.gridCrossings(of: line, origin: .zero, every: 100).map(\.distance)

        #expect(crossings == [90, 190])
    }

    @Test("the grid is the world's, not the tile's: the same line further east crosses it elsewhere")
    func crossingsFollowTheOrigin() {
        let line = [CGPoint(x: 10, y: 50), CGPoint(x: 250, y: 50)]

        let crossings = VectorTileShields.gridCrossings(of: line, origin: CGPoint(x: 30, y: 0), every: 100)
            .map(\.distance)

        #expect(crossings == [60, 160])
    }

    @Test("a line along the grid, or shorter than the way to its next line, crosses nothing")
    func noCrossing() {
        let short = [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)]
        let along = [CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 90)]

        #expect(VectorTileShields.gridCrossings(of: short, origin: .zero, every: 100).isEmpty)
        #expect(VectorTileShields.gridCrossings(of: along, origin: .zero, every: 100).isEmpty)
        #expect(VectorTileShields.gridCrossings(of: short, origin: .zero, every: 0).isEmpty)
    }

    @Test("a road is numbered only from its zoom on")
    func numberedFromItsZoom() throws {
        let road = motorway(ref: "A 3")
        let tile = try VectorTileFixture.decoded([.init(name: "roads", features: [road])])
        let wide = VectorTileAddress(z: 9, x: 0, y: 0)
        let close = VectorTileAddress(z: 10, x: 0, y: 0)

        #expect(VectorTileShields.lines(in: tile, source: wide, target: wide).isEmpty)
        #expect(VectorTileShields.lines(in: tile, source: close, target: close).map(\.numbers) == [["A 3"]])
    }

    @Test("a road's pieces with one number are joined, and the more important road comes first")
    func joinedAndOrdered() throws {
        let first = feature(kind: "major_road", detail: "tertiary", ref: "K 1", points: [(0, 100), (grid / 2, 100)])
        let second = feature(kind: "major_road", detail: "tertiary", ref: "K 1", points: [(grid / 2, 100), (grid, 100)])
        let roads = VectorTileFixture.Layer(name: "roads", features: [first, second, motorway(ref: "A 3")])
        let tile = try VectorTileFixture.decoded([roads])
        let address = VectorTileAddress(z: 13, x: 0, y: 0)

        let lines = VectorTileShields.lines(in: tile, source: address, target: address)

        #expect(lines.map(\.numbers) == [["A 3"], ["K 1"]])
        #expect(lines.last?.points.count == 3, "the two pieces as one line")
    }

    /// The tile at the world's origin holds grid lines at every multiple of
    /// the spacing, so a road across its middle crosses one.
    @Test("a plate stands on its road, inside the tile, and takes its room")
    func plateOnItsRoad() throws {
        let layout = try plates(for: [motorway(ref: "A 3")], at: VectorTileAddress(z: 12, x: 0, y: 0))

        let frame = try #require(layout.frames.first)
        #expect(bounds.contains(frame))
        #expect(abs(frame.midY - side / 2) < 1, "centred on the road, which runs across the tile's middle")
    }

    @Test("two carriageways with one number share a plate")
    func oneNumberOnce() throws {
        let north = feature(kind: "highway", detail: "motorway", ref: "A 3", points: [(0, grid / 2), (grid, grid / 2)])
        let south = feature(
            kind: "highway",
            detail: "motorway",
            ref: "A 3",
            points: [(0, grid / 2 + 40), (grid, grid / 2 + 40)]
        )
        let both = try plates(for: [north, south], at: VectorTileAddress(z: 12, x: 0, y: 0))
        let one = try plates(for: [north], at: VectorTileAddress(z: 12, x: 0, y: 0))

        #expect(!one.frames.isEmpty)
        #expect(both.frames.count == one.frames.count)
    }

    @Test("a plate keeps clear of what was placed before it")
    func plateKeepsClear() throws {
        let address = VectorTileAddress(z: 12, x: 0, y: 0)
        let free = try plates(for: [motorway(ref: "A 3")], at: address)
        let taken = try plates(for: [motorway(ref: "A 3")], at: address, taken: [bounds])

        #expect(!free.frames.isEmpty)
        #expect(taken.frames.isEmpty)
    }

    /// The grid's lines are 760 of the pictures' pixels apart and the tiles
    /// 512, so every 64th line runs along a seam: x = 48,640, between the
    /// tiles 94 and 95 across. Each tile sees its own stretch of a road, cut
    /// at its buffer and on the archive's grid, so where the road crosses
    /// the line, worked out along that stretch, lands a rounding either side
    /// of the seam. The grid line's own place decides which of the two
    /// numbers it.
    @Test("a road that crosses the grid on a seam is numbered once")
    func plateOnASeam() {
        for index in 0..<40 {
            let step = CGFloat(index)
            let start = CGPoint(x: 48_000.37 + 0.37 * step, y: 180.3 + 1.3 * step)
            let end = CGPoint(x: 49_300.11 - 0.29 * step, y: 260.7 + 0.7 * step)
            let placed = (94...95).map { column in
                let corner = CGFloat(column) * side
                // Cut 16 pixels outside the tile, on an eighth of a pixel.
                let enters = (corner - 16 - start.x) / (end.x - start.x)
                let leaves = (corner + side + 16 - start.x) / (end.x - start.x)
                let points = [enters, leaves].map { share in
                    CGPoint(
                        x: ((start.x + (end.x - start.x) * share - corner) * 8).rounded() / 8,
                        y: ((start.y + (end.y - start.y) * share) * 8).rounded() / 8
                    )
                }
                let line = VectorTileShields.NumberedLine(
                    road: .motorway,
                    numbers: ["A 3"],
                    points: points,
                    length: hypot(points[1].x - points[0].x, points[1].y - points[0].y)
                )
                var room = VectorTilePoints.Room(bounds: bounds, taken: [])
                var fonts = LabelFonts(language: "en")
                return VectorTileShields.Layout(
                    [line],
                    target: VectorTileAddress(z: 12, x: column, y: 0),
                    unit: unit,
                    room: &room,
                    fonts: &fonts
                )
                .frames.count
            }

            #expect(placed.reduce(0, +) == 1, "road \(index): \(placed)")
        }
    }

    // MARK: Helpers

    private func motorway(ref: String) -> VectorTileFixture.Feature {
        feature(kind: "highway", detail: "motorway", ref: ref, points: [(0, grid / 2), (grid, grid / 2)])
    }

    private func feature(kind: String, detail: String, ref: String, points: [(Int, Int)]) -> VectorTileFixture.Feature {
        .init(
            type: .line,
            properties: ["kind": .string(kind), "kind_detail": .string(detail), "ref": .string(ref)],
            geometry: VectorTileFixture.line(points)
        )
    }

    private func plates(
        for roads: [VectorTileFixture.Feature],
        at address: VectorTileAddress,
        taken: [CGRect] = []
    ) throws -> VectorTileShields.Layout {
        let tile = try VectorTileFixture.decoded([.init(name: "roads", features: roads)])
        var room = VectorTilePoints.Room(bounds: bounds, taken: taken)
        var fonts = LabelFonts(language: "en")
        return VectorTileShields.Layout(
            VectorTileShields.lines(in: tile, source: address, target: address),
            target: address,
            unit: unit,
            room: &room,
            fonts: &fonts
        )
    }
}
