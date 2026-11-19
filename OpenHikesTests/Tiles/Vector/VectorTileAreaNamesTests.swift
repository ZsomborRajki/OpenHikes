//
//  VectorTileAreaNamesTests.swift
//  OpenHikesTests
//
//  The names of areas — forests, parks, protected areas, islands — which
//  Carto draws by an area's size on the screen: that the table the app ships
//  says what Carto's rules say for each size, and that a point the vector
//  extras give with its size takes the place of the basemap's point for the
//  same area. Tiles are written by `VectorTileFixture`.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile area names")
struct VectorTileAreaNamesTests {
    private let style = VectorTilePointStyle.bundled
    private let tile = VectorTileAddress(z: 12, x: 2179, y: 1421)
    private let grid = VectorTileFixture.grid

    // MARK: The table

    /// Carto names a forest from zoom 8 once it covers 3,000 square pixels,
    /// in 10, 12 or 15 points as it passes 12,000 and 48,000.
    @Test("a forest is named from zoom 8 once it covers 3,000 square pixels, and larger the larger it is")
    func forestBySize() {
        let size = { (pixels: Double?, z: Int) in
            style.look(kind: "forest", detail: nil, named: true, z: z, pixels: pixels)?.text?.size
        }

        #expect(size(2000, 8) == nil)
        #expect(size(4000, 7) == nil)
        #expect(size(4000, 8) == 10)
        #expect(size(20_000, 8) == 12)
        #expect(size(100_000, 8) == 15)
        #expect(size(nil, 8) == nil, "a point the basemap gives has no size, and waits as a point does")
        #expect(size(nil, 17) == 10)
    }

    @Test("a park waits for zoom 10, an islet for 11, and an island is named from zoom 4")
    func firstZooms() {
        let named = { (kind: String, z: Int) in
            style.look(kind: kind, detail: nil, named: true, z: z, pixels: 4000)?.text != nil
        }

        #expect(!named("park", 9))
        #expect(named("park", 10))
        #expect(!named("islet", 10))
        #expect(named("islet", 11))
        #expect(!named("island", 3))
        #expect(named("island", 4))
    }

    /// Carto's query leaves out an area past 768,000 square pixels; a
    /// protected area that large is named along its edge instead, which the
    /// map does not draw.
    @Test("an area larger than Carto names at a point is not drawn there")
    func tooLargeForAPoint() {
        #expect(style.areaLimit == 768_000)
        #expect(style.look(kind: "forest", detail: nil, named: true, z: 10, pixels: 700_000) != nil)
        #expect(style.look(kind: "forest", detail: nil, named: true, z: 10, pixels: 800_000) == nil)
    }

    @Test("a car park is marked from zoom 14 once it covers 750 square pixels, faded where it is private")
    func carParkBySize() throws {
        #expect(style.look(kind: "parking", detail: nil, named: false, z: 14, pixels: 500) == nil)
        let open = try #require(style.look(kind: "parking", detail: nil, named: false, z: 14, pixels: 1000))
        let closed = try #require(
            style.look(kind: "parking", detail: nil, named: false, z: 14, access: "private", pixels: 1000)
        )

        #expect(open.icons.first?.asset == "carto-amenity-parking")
        #expect(open.icons.first?.opacity == 1)
        #expect(try #require(closed.icons.first?.opacity) < 1)
    }

    /// The extras carry a car park's `parking` as its detail, because Carto
    /// marks parking along a street, or in a lane of it, only from zoom 18,
    /// and with a quieter icon, however large it is: way 995944380, a lane
    /// of 1,139 square pixels at zoom 15, took the car park's icon there.
    @Test(
        "parking along a street or in a lane is marked from zoom 18 alone, with Carto's quieter icon",
        arguments: ["street_side", "lane"]
    )
    func streetParking(parking: String) throws {
        let marked = { (z: Int, pixels: Double?) in
            style.look(kind: "parking", detail: parking, named: false, z: z, pixels: pixels)
        }

        #expect(marked(15, 1139) == nil)
        #expect(marked(17, nil) == nil)
        #expect(try #require(marked(18, 1139)).icons.first?.asset == "carto-amenity-parking_subtle")
        #expect(
            style.look(kind: "parking", detail: "surface", named: false, z: 15, pixels: 1139)?.icons.first?.asset
                == "carto-amenity-parking",
            "any other car park is marked as before"
        )
    }

    @Test("a car park's detail is read from the extras' point")
    func streetParkingFromTheTile() throws {
        let wide = VectorTileAddress(z: 15, x: tile.x << 3, y: tile.y << 3)
        let lane = point([
            "kind": .string("parking"), "kind_detail": .string("lane"), "area": .double(area(1139, at: wide.z)),
        ])
        let surface = point(
            ["kind": .string("parking"), "kind_detail": .string("surface"), "area": .double(area(1139, at: wide.z))],
            at: (grid / 4, grid / 4)
        )

        let points = try candidates([lane, surface], at: wide)

        #expect(points.map(\.look.icons.first?.asset) == ["carto-amenity-parking"])
    }

    /// The extras carry a protected area's class as its detail, because
    /// Carto draws only the classes from 1 to 6.
    @Test("a protected area is named only for the classes Carto draws")
    func protectedAreaClasses() {
        let named = { (protectClass: String?) in
            style.look(kind: "protected_area", detail: protectClass, named: true, z: 8, pixels: 4000)?.text != nil
        }

        #expect(named("1a"))
        #expect(named("5"))
        #expect(!named("7"))
        #expect(!named(nil))
        #expect(style.look(kind: "national_park", detail: nil, named: true, z: 8, pixels: 4000)?.text != nil)
    }

    // MARK: Choosing

    /// The basemap and the extras cut a named area's point with the same
    /// Planetiler call, so the two stand on the same step of the grid. At
    /// zoom 17 Carto names every park, so the basemap's would be drawn too.
    @Test("the extras' point for an area takes the place of the basemap's at the same spot")
    func extrasReplaceTheBasemapsPoint() throws {
        let deep = VectorTileAddress(z: 17, x: tile.x << 5, y: tile.y << 5)
        let garden = "Englischer Garten"
        let features = [
            point(["kind": .string("park"), "name": .string(garden)]),
            point(["kind": .string("park"), "name": .string(garden), "area": .double(area(20_000, at: deep.z))]),
        ]

        let points = try candidates(features, at: deep)

        #expect(points.map(\.lines) == [[garden]])
        #expect(points.first?.look.text?.size == 12)
        #expect(points.first?.rank.pixels == 20_000)
    }

    @Test("a basemap point of the same name elsewhere is kept")
    func sameNameElsewhereIsKept() throws {
        let deep = VectorTileAddress(z: 17, x: tile.x << 5, y: tile.y << 5)
        let features = [
            point(["kind": .string("park"), "name": .string("Hofgarten"), "area": .double(area(20_000, at: deep.z))]),
            point(["kind": .string("park"), "name": .string("Hofgarten")], at: (grid / 4, grid / 4)),
        ]

        let points = try candidates(features, at: deep)

        #expect(points.map(\.rank.pixels) == [20_000, 0])
    }

    @Test("the larger area claims room first, as Carto orders areas")
    func largerAreaFirst() throws {
        let points = try candidates([
            point(["kind": .string("forest"), "name": .string("Alpski gozd"), "area": .double(area(4000))]),
            point(
                ["kind": .string("forest"), "name": .string("Zgornji gozd"), "area": .double(area(60_000))],
                at: (grid / 4, grid / 4)
            ),
        ])

        #expect(points.map(\.lines.first) == ["Zgornji gozd", "Alpski gozd"], "by size, not by name")
    }

    // MARK: Helpers

    /// The `area` the extras would give an area of `pixels` at zoom `z`,
    /// the suite's by default: its size on the whole world drawn as one
    /// 256-pixel tile.
    private func area(_ pixels: Double, at z: Int? = nil) -> Double {
        pixels / pow(4, Double(z ?? tile.z))
    }

    private func point(
        _ properties: [String: VectorTileFixture.Value],
        at position: (Int, Int)? = nil
    ) -> VectorTileFixture.Feature {
        let spot = position ?? (grid / 2, grid / 2)
        return .init(type: .point, properties: properties, geometry: VectorTileFixture.points([spot]))
    }

    /// The candidates of a tile of `features` at `address`, the suite's
    /// tile by default.
    private func candidates(
        _ features: [VectorTileFixture.Feature],
        at address: VectorTileAddress? = nil
    ) throws -> [VectorTilePoints.Candidate] {
        let decoded = try VectorTileFixture.decoded([.init(name: "pois", features: features)])
        return VectorTilePoints.candidates(
            in: decoded,
            source: address ?? tile,
            target: address ?? tile,
            language: "en",
            height: VectorTileFixture.height,
            style: style
        )
    }
}
