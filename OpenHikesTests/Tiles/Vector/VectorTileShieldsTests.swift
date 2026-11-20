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

        let crossings = VectorTileShields.crossings(of: line, origin: .zero, every: 100)

        #expect(crossings == [90, 190])
    }

    @Test("the grid is the world's, not the tile's: the same line further east crosses it elsewhere")
    func crossingsFollowTheOrigin() {
        let line = [CGPoint(x: 10, y: 50), CGPoint(x: 250, y: 50)]

        let crossings = VectorTileShields.crossings(of: line, origin: CGPoint(x: 30, y: 0), every: 100)

        #expect(crossings == [60, 160])
    }

    @Test("a line along the grid, or shorter than the way to its next line, crosses nothing")
    func noCrossing() {
        let short = [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)]
        let along = [CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 90)]

        #expect(VectorTileShields.crossings(of: short, origin: .zero, every: 100).isEmpty)
        #expect(VectorTileShields.crossings(of: along, origin: .zero, every: 100).isEmpty)
        #expect(VectorTileShields.crossings(of: short, origin: .zero, every: 0).isEmpty)
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
