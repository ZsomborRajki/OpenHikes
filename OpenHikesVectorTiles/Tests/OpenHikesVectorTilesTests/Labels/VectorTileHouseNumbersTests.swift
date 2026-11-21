//
//  VectorTileHouseNumbersTests.swift
//  OpenHikesVectorTilesTests
//
//  House numbers on a drawn tile, read from tiles written by
//  `VectorTileFixture`: which addresses are numbered and from which zoom,
//  how a long list of numbers is shortened, and the room a number keeps
//  from what was placed before it and from the tile's edge.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
import Testing

@Suite("Vector tile house numbers")
struct VectorTileHouseNumbersTests {
    private let tile = VectorTileAddress(z: 17, x: 72_473, y: 45_833)
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }
    private let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize

    // MARK: Choosing

    /// The archive keeps an address as a point of kind `address` in its
    /// `buildings` layer, beside the buildings themselves.
    @Test("an address is numbered where it stands, and a building or a point beyond the tile is not")
    func whatIsNumbered() throws {
        let building = VectorTileFixture.Feature(
            type: .polygon,
            properties: ["kind": .string("building")],
            geometry: VectorTileFixture.rectangle(x: 0...(grid / 2), y: 0...(grid / 2))
        )
        let inside = address("24", at: (grid / 4, grid / 4))
        let beyond = address("16", at: (grid + grid / 8, grid / 2))

        let numbers = try candidates([inside, beyond, building], at: tile)

        #expect(numbers.map(\.lines) == [["24"]])
        #expect(numbers.first?.anchor == CGPoint(x: side / 4, y: side / 4))
    }

    @Test("Carto writes house numbers from zoom 17")
    func notBeforeZoom17() throws {
        let wide = VectorTileAddress(z: 16, x: tile.x / 2, y: tile.y / 2)

        #expect(try candidates([address("24")], at: wide).isEmpty)
    }

    @Test(
        "a long list of numbers is written as its first and last, as Carto shortens one",
        arguments: [
            ("12", "12"),
            ("1;3;5;7;9;11", "1\u{2026}\u{2060}11"),
            ("10,12,14,16", "10\u{2026}\u{2060}16"),
            ("1234567;891011", "1234567;891011"),
            ("1,3;5;7;9;11", "1,3;5;7;9;11"),
            ("12-14", "12-14"),
        ]
    )
    func shortening(number: String, written: String) {
        #expect(VectorTileHouseNumbers.shortened(number) == written)
    }

    @Test("a number is written in Carto's gray, with a wider halo from zoom 18")
    func look() throws {
        let near = try #require(VectorTileHouseNumbers.look(z: 17).text)
        let nearer = try #require(VectorTileHouseNumbers.look(z: 18).text)

        #expect(near.size == 10)
        #expect(near.color == VectorTileStyle.color("#666666"))
        #expect(nearer.haloRadius > near.haloRadius)
        #expect(VectorTileHouseNumbers.look(z: 17).icons.isEmpty)
    }

    // MARK: Placing

    /// Carto keeps a number three pixels clear of every name placed before
    /// it, where a point's name keeps none.
    @Test("a number keeps Carto's margin from what was placed before it")
    func numbersKeepTheirMargin() throws {
        let numbers = try candidates([address("24")], at: tile)
        var fonts = LabelFonts(language: "en")
        var measuring = VectorTilePoints.Room(bounds: bounds, taken: [])
        let alone = VectorTilePoints.Names(numbers, unit: unit, room: &measuring, fonts: &fonts)
        let frame = try #require(alone.frames.first)
        // A name ending a pixel short of the number.
        let name = CGRect(x: frame.minX - 41, y: frame.minY, width: 40, height: frame.height)
        var room = VectorTilePoints.Room(bounds: bounds, taken: [name])
        var plainRoom = VectorTilePoints.Room(bounds: bounds, taken: [name])

        let kept = VectorTilePoints.Names(
            numbers,
            unit: unit,
            room: &room,
            fonts: &fonts,
            margin: VectorTileHouseNumbers.margin * unit
        )
        let plain = VectorTilePoints.Names(numbers, unit: unit, room: &plainRoom, fonts: &fonts)

        #expect(kept.count == 0)
        #expect(plain.count == 1)
    }

    /// Two tiles place their numbers without seeing each other's, so each
    /// keeps its halo and Carto's margin inside its own edge: `12` and `14`
    /// either side of a seam at zoom 18 stood two pixels apart, reading
    /// `1214`.
    @Test("two numbers either side of a tile's edge keep its margin apart, halos and all")
    func numbersKeepApartAcrossTheEdge() throws {
        let left = VectorTileAddress(z: 18, x: 144_946, y: 91_666)
        let right = VectorTileAddress(z: 18, x: left.x + 1, y: left.y)
        let twelve = try placed(address("12", at: (grid - 4, grid / 2)), at: left)
        let fourteen = try placed(address("14", at: (4, grid / 2)), at: right)
        let halo = try #require(VectorTileHouseNumbers.look(z: 18).text?.haloRadius) * unit
        let margin = VectorTileHouseNumbers.margin * unit

        #expect(twelve.maxX + halo + margin <= side)
        #expect(fourteen.minX - halo - margin >= 0)
    }

    @Test("a number is drawn on the map at zoom 17, and not at zoom 16")
    func numbersAreDrawn() throws {
        let land = VectorTileFixture.Layer(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
        let layers = [land, .init(name: "buildings", features: [address("111")])]
        let wide = VectorTileAddress(z: 16, x: tile.x / 2, y: tile.y / 2)

        let near = try #require(try VectorTileFixture.image(layers, from: tile, drawing: tile))
        let wider = try #require(try VectorTileFixture.image(layers, from: wide, drawing: wide))

        // Nothing else on the tile is near the number's gray.
        #expect(VectorTileFixture.image(near, has: "#666666", tolerance: letterTolerance))
        #expect(!VectorTileFixture.image(wider, has: "#666666", tolerance: letterTolerance))
    }

    // MARK: Helpers

    /// A letter's stroke may cover no pixel whole, so its ink is matched
    /// loosely.
    private let letterTolerance = 16

    private func address(_ number: String, at position: (Int, Int)? = nil) -> VectorTileFixture.Feature {
        .init(
            type: .point,
            properties: ["kind": .string("address"), "addr_housenumber": .string(number)],
            geometry: VectorTileFixture.points([position ?? (grid / 2, grid / 2)])
        )
    }

    /// Where `number` stands on `target` placed alone, as the map places
    /// house numbers.
    private func placed(_ number: VectorTileFixture.Feature, at target: VectorTileAddress) throws -> CGRect {
        var room = VectorTilePoints.Room(bounds: bounds, taken: [])
        var fonts = LabelFonts(language: "en")
        let names = VectorTilePoints.Names(
            try candidates([number], at: target),
            unit: unit,
            room: &room,
            fonts: &fonts,
            margin: VectorTileHouseNumbers.margin * unit
        )
        return try #require(names.frames.first)
    }

    private func candidates(
        _ features: [VectorTileFixture.Feature],
        at target: VectorTileAddress
    ) throws -> [VectorTilePoints.Candidate] {
        let decoded = try VectorTileFixture.decoded([.init(name: "buildings", features: features)])
        return VectorTileHouseNumbers.candidates(in: decoded, source: target, target: target)
    }
}
