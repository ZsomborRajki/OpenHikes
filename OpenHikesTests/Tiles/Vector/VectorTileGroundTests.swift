//
//  VectorTileGroundTests.swift
//  OpenHikesTests
//
//  What a drawn tile shows of the ground beyond its fills, from tiles written
//  by `VectorTileFixture` and drawn with Carto's own patterns out of the
//  asset catalog: a wood's trees and a wetland's fill and marks, water that
//  is not always there drawn broken, the red tint over military land, the
//  lines cut through a forest, cliffs with their teeth, and trees.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile ground")
struct VectorTileGroundTests {
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)

    private let land = VectorTileFixture.color("#F2EFE9")
    private let water = VectorTileFixture.color("#AAD3DF")
    private let wood = VectorTileFixture.color("#ADD19E")

    /// The middle of the tile, as the grid and as the picture have it.
    private var middle: ClosedRange<Int> { (grid / 4)...(grid * 3 / 4) }
    private var inside: CGRect { VectorTileFixture.pixels(x: middle, y: middle) }
    /// A strip of land above the middle, which nothing below is drawn on.
    private var beside: CGRect { VectorTileFixture.pixels(x: middle, y: 0...(grid / 8)) }

    private var earth: VectorTileFixture.Layer {
        .init(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
    }

    private func area(
        _ kind: String,
        detail: String? = nil,
        id: UInt64? = nil
    ) -> VectorTileFixture.Feature {
        var properties: [String: VectorTileFixture.Value] = ["kind": .string(kind)]
        if let detail { properties["kind_detail"] = .string(detail) }
        return .init(
            type: .polygon,
            properties: properties,
            geometry: VectorTileFixture.rectangle(x: middle, y: middle),
            id: id
        )
    }

    /// A line across the middle of the tile, running to the right.
    private func line(_ kind: String, reversed: Bool = false) -> VectorTileFixture.Feature {
        let ends = [(grid / 8, grid / 2), (grid * 7 / 8, grid / 2)]
        return .init(
            type: .line,
            properties: ["kind": .string(kind)],
            geometry: VectorTileFixture.line(reversed ? ends.reversed() : ends)
        )
    }

    /// A band of the picture `reach` pixels either side of the middle line.
    private func band(reach: CGFloat, from top: CGFloat? = nil) -> CGRect {
        CGRect(x: side / 4, y: side / 2 + (top ?? -reach), width: side / 2, height: top.map { reach - $0 } ?? 2 * reach)
    }

    private func draw(_ layers: [VectorTileFixture.Layer], z: Int) throws -> CGImage {
        let tile = VectorTileAddress(z: z, x: 1 << (z - 1), y: 1 << (z - 1))
        return try #require(try VectorTileFixture.image([earth] + layers, from: tile, drawing: tile))
    }

    private func colors(_ layers: [VectorTileFixture.Layer], z: Int, in rect: CGRect) throws -> Set<Int> {
        VectorTileFixture.colors(of: try draw(layers, z: z), in: rect)
    }

    private func bytes(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    // MARK: Woods and wetlands

    @Test("a wood is filled plain until zoom 13, and from there has Carto's trees over the fill")
    func woodsHaveTrees() throws {
        let woods = VectorTileFixture.Layer(name: "landuse", features: [area("wood")])

        #expect(try colors([woods], z: 12, in: inside) == [wood])
        let drawn = try colors([woods], z: 13, in: inside)
        #expect(drawn.contains(wood))
        #expect(drawn.count > 1, "the trees")
        #expect(try colors([woods], z: 13, in: beside) == [land])
    }

    @Test("the extras' word for a wood's id picks its trees, and their word for another wood changes nothing")
    func leavesPickTheTrees() throws {
        let id: UInt64 = 35_184_464_027_747
        let woods = VectorTileFixture.Layer(name: "landuse", features: [area("wood", id: id)])
        let detail = { (id: UInt64) in
            VectorTileFixture.Layer(name: VectorTileAreaDetails.layerName, features: [
                VectorTileFixture.Feature(
                    type: .polygon,
                    properties: ["kind_detail": .string("needleleaved")],
                    geometry: VectorTileFixture.rectangle(x: 0...8, y: 0...8),
                    id: id
                ),
            ])
        }

        let plain = try draw([woods], z: 13)
        let conifers = try draw([woods, detail(id)], z: 13)
        let others = try draw([woods, detail(id + 1)], z: 13)

        #expect(bytes(conifers) != bytes(plain))
        #expect(bytes(others) == bytes(plain))
        #expect(VectorTileFixture.colors(of: conifers, in: beside) == [land], "the detail's own shape is never drawn")
    }

    /// Carto fills a wetland by its kind and otherwise only marks it.
    @Test("a wetland of no kind has no fill and, from zoom 10, its marks; a bog is filled as heath")
    func wetlands() throws {
        let plain = VectorTileFixture.Layer(name: "landuse", features: [area("wetland")])
        let bog = VectorTileFixture.Layer(name: "landuse", features: [area("wetland", detail: "bog")])
        let heath = VectorTileFixture.color("#D6D99F")

        #expect(try colors([plain], z: 9, in: inside) == [land])
        let marked = try colors([plain], z: 10, in: inside)
        #expect(marked.contains(land))
        #expect(marked.count > 1, "the marks")
        #expect(try colors([bog], z: 9, in: inside) == [heath])
        #expect(try colors([bog], z: 13, in: inside).contains(heath))
        #expect(VectorTileStyle.wetlandFill(detail: "swamp") == VectorTileStyle.landuseFills["wood"])
        #expect(VectorTileStyle.wetlandFill(detail: "pond") == nil)
    }

    /// Most mud lies in the sea, which would cover a fill drawn with the
    /// ground.
    @Test("mud and a tidal flat are tinted over the water they lie in, from zoom 9", arguments: [
        ("mud", nil), ("wetland", "tidalflat"),
    ])
    func mudOverWater(kind: String, detail: String?) throws {
        let sea = VectorTileFixture.Layer(name: "water", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("ocean")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
        let flats = VectorTileFixture.Layer(name: "landuse", features: [area(kind, detail: detail)])

        #expect(try colors([sea, flats], z: 8, in: inside) == [water])
        let tinted = try colors([sea, flats], z: 9, in: inside)
        #expect(tinted.count == 1)
        #expect(tinted != [water])
        #expect(try colors([sea, flats], z: 9, in: beside) == [water])
        #expect(VectorTileStyle.wetlandFill(detail: "tidalflat") == nil, "not with the ground")
        #expect(VectorTileStyle.landuseFills["mud"] == nil)
    }

    @Test("scree has its dots over its fill from zoom 13, and a smaller area drawn over it covers them")
    func patternOverFill() throws {
        let scree = VectorTileFixture.color("#EEE5DC")
        let core = (grid * 3 / 8)...(grid * 5 / 8)
        let meadow = VectorTileFixture.Feature(
            type: .polygon,
            properties: ["kind": .string("meadow")],
            geometry: VectorTileFixture.rectangle(x: core, y: core)
        )
        let covered = VectorTileFixture.pixels(x: core, y: core)
        let layer = VectorTileFixture.Layer(name: "landuse", features: [meadow, area("scree")])

        #expect(try colors([layer], z: 12, in: VectorTileFixture.pixels(x: middle, y: middle, inset: 8))
            == [scree, VectorTileFixture.color("#CDEBB0")])
        #expect(try colors([layer], z: 13, in: inside).count > 2, "the dots")
        #expect(try colors([layer], z: 13, in: covered) == [VectorTileFixture.color("#CDEBB0")])
    }

    // MARK: Waterways

    @Test("a waterway is as wide as Carto draws it: a river from zoom 8, a stream from 12")
    func waterwayWidths() throws {
        let river = try #require(VectorTileStyle.waterLineWidths["river"])
        let stream = try #require(VectorTileStyle.waterLineWidths["stream"])
        let ditch = try #require(VectorTileStyle.waterLineWidths["ditch"])
        let canal = try #require(VectorTileStyle.waterLineWidths["canal"])

        #expect(river.value(at: 7) == 0)
        #expect(river.value(at: 13) == 3)
        #expect(river.value(at: 15) == 6)
        #expect(stream.value(at: 11) == 0)
        #expect(stream.value(at: 14) == 2)
        #expect(stream.value(at: 16) == 3)
        #expect(ditch.value(at: 14) == stream.value(at: 14))
        #expect(ditch.value(at: 16) < stream.value(at: 16), "a ditch stops widening")
        #expect(canal.value(at: 11) == 0, "before zoom 12 Carto draws the rivers and nothing else")
        #expect(canal.value(at: 12) > 0)
        #expect(canal.value(at: 14) > stream.value(at: 14))
        #expect(canal.value(at: 14) < river.value(at: 14))
    }

    /// The glow keeps a stream readable through a wood.
    @Test("a stream has a pale glow under it from zoom 13 to 17, a canal to 14, and a river none")
    func waterwayGlow() throws {
        #expect(VectorTileStyle.waterGlow(kind: "stream", z: 12) == nil)
        #expect(VectorTileStyle.waterGlow(kind: "stream", z: 18) == nil)
        #expect(VectorTileStyle.waterGlow(kind: "canal", z: 15) == nil)
        #expect(VectorTileStyle.waterGlow(kind: "canal", z: 14) != nil)
        #expect(VectorTileStyle.waterGlow(kind: "river", z: 14) == nil)

        let glow = try #require(VectorTileStyle.waterGlow(kind: "stream", z: 14))
        let stream = try #require(VectorTileStyle.waterLineWidths["stream"])
        #expect(glow.width.value(at: 14) > stream.value(at: 14))
        #expect(glow.alpha < 1)

        let woods = VectorTileFixture.Layer(name: "landuse", features: [area("wood")])
        let brook = VectorTileFixture.Layer(name: "water", features: [line("stream")])
        let edge = band(reach: 3, from: 2).insetBy(dx: 8, dy: 0)
        #expect(try colors([woods, brook], z: 12, in: edge) == [wood])
        #expect(try colors([woods, brook], z: 14, in: edge) != [wood], "paler beside the stream")
    }

    // MARK: Water that is not always there

    @Test("a stream the extras say runs only part of the year is drawn broken")
    func intermittentStream() throws {
        let stream = VectorTileFixture.Layer(name: "water", features: [line("stream")])
        let seasonal = VectorTileFixture.Layer(name: VectorTileRasterizer.intermittentLayer, features: [line("stream")])
        let along = band(reach: 1)

        #expect(try colors([stream], z: 14, in: along) == [water])
        let broken = try colors([stream, seasonal], z: 14, in: along)
        #expect(broken.contains(water))
        #expect(broken.contains(land), "the gaps")
    }

    /// The ground under the stream is not rubbed out with the gaps.
    @Test("the gaps in a stream show the ground it runs over")
    func gapsShowTheGround() throws {
        let stream = VectorTileFixture.Layer(name: "water", features: [line("stream")])
        let seasonal = VectorTileFixture.Layer(name: VectorTileRasterizer.intermittentLayer, features: [line("stream")])
        let woods = VectorTileFixture.Layer(name: "landuse", features: [area("wood")])

        let drawn = try colors([woods, stream, seasonal], z: 12, in: band(reach: 1).insetBy(dx: 8, dy: 0))

        #expect(drawn.contains(wood))
        #expect(!drawn.contains(land))
    }

    @Test("a lake the extras say is not always there is drawn as lines of water over the ground")
    func intermittentLake() throws {
        let lake = VectorTileFixture.Layer(name: "water", features: [area("lake")])
        let dry = VectorTileFixture.Layer(name: VectorTileRasterizer.intermittentLayer, features: [area("water")])

        #expect(try colors([lake], z: 13, in: inside) == [water])
        let drawn = try colors([lake, dry], z: 13, in: inside)
        #expect(drawn.contains(water))
        #expect(drawn.contains(land))
        #expect(VectorTileStyle.intermittentDash(z: 11).dash > VectorTileStyle.intermittentDash(z: 12).dash)
    }

    // MARK: Closed to the public

    @Test("military land is tinted and hatched in red from zoom 8, over the ground it is on", arguments: [
        "military", "naval_base", "airfield",
    ])
    func militaryLand(kind: String) throws {
        let base = VectorTileFixture.Layer(name: "landuse", features: [area(kind)])

        #expect(try colors([base], z: 7, in: inside) == [land])
        let drawn = try colors([base], z: 8, in: inside)
        #expect(!drawn.contains(land))
        #expect(drawn.count > 1, "the tint and the hatch over it")
        #expect(try colors([base], z: 8, in: beside) == [land])
    }

    @Test("a danger area is marked from zoom 9, and a kind that is neither is not marked")
    func dangerAreas() throws {
        let range = VectorTileFixture.Layer(name: "landuse", features: [area("danger_area")])

        #expect(try colors([range], z: 8, in: inside) == [land])
        #expect(try !colors([range], z: 9, in: inside).contains(land))
        #expect(VectorTileStyle.restricted(kind: "danger_area", z: 8) == nil)
        #expect(VectorTileStyle.restricted(kind: "residential", z: 15) == nil)
        #expect(VectorTileStyle.landuseFills["military"] == nil)
    }

}

// MARK: Lines and trees

extension VectorTileGroundTests {
    @Test("a line cut through a forest is drawn in the grass's green from zoom 14")
    func cutlines() throws {
        let cut = VectorTileFixture.Layer(name: VectorTileRasterizer.cutlinesLayer, features: [line("cutline")])
        let grass = VectorTileFixture.color("#CDEBB0")

        #expect(try colors([cut], z: 13, in: band(reach: 1)) == [land])
        #expect(try colors([cut], z: 14, in: band(reach: 1)) == [grass])
        #expect(VectorTileStyle.cutline.width.value(at: 16) > VectorTileStyle.cutline.width.value(at: 15))
    }

    /// The fixture's line runs to the right, so the drop is below it.
    @Test("a cliff from the extras has its teeth on the right of the way it runs", arguments: [false, true])
    func cliffTeeth(reversed: Bool) throws {
        let cliff = VectorTileFixture.Layer(
            name: VectorTileRasterizer.cliffsLayer,
            features: [line("cliff", reversed: reversed)]
        )
        let above = band(reach: -2, from: -8)
        let below = band(reach: 8, from: 2)

        let image = try draw([cliff], z: 13)

        #expect(VectorTileFixture.colors(of: image, in: reversed ? below : above) == [land])
        #expect(VectorTileFixture.colors(of: image, in: reversed ? above : below).count > 1, "the teeth")
        #expect(try colors([cliff], z: 12, in: band(reach: 8)) == [land])
    }

    /// The basemap's cliff has no side to it: its build may have turned it.
    @Test("the basemap's cliff is drawn plain, and only on a tile the extras gave no cliffs for")
    func basemapCliffs() throws {
        let plain = VectorTileFixture.Layer(name: "earth", features: earth.features + [line("cliff")])
        let toothed = VectorTileFixture.Layer(name: VectorTileRasterizer.cliffsLayer, features: [line("cliff")])
        let tile = VectorTileAddress(z: 13, x: 1 << 12, y: 1 << 12)
        let image = { (layers: [VectorTileFixture.Layer]) in
            try #require(try VectorTileFixture.image(layers, from: tile, drawing: tile))
        }

        let alone = try image([plain])
        #expect(VectorTileFixture.colors(of: alone, in: band(reach: 1)) != [land], "the line")
        #expect(VectorTileFixture.colors(of: alone, in: band(reach: 8, from: 3)) == [land], "no teeth")
        #expect(bytes(try image([plain, toothed])) == bytes(try image([earth, toothed])))
    }

    @Test("an embankment has its teeth from zoom 15, and a ridge Carto's dots from 14")
    func embankmentsAndRidges() throws {
        let bank = VectorTileFixture.Layer(name: VectorTileRasterizer.cliffsLayer, features: [line("embankment")])
        let ridge = VectorTileFixture.Layer(name: VectorTileRasterizer.ridgesLayer, features: [line("ridge")])

        #expect(try colors([bank], z: 14, in: band(reach: 8)) == [land])
        #expect(try colors([bank], z: 15, in: band(reach: 8)).count > 1)
        #expect(try colors([ridge], z: 13, in: band(reach: 16)) == [land])
        #expect(try colors([ridge], z: 14, in: band(reach: 16)).count > 1)
        // Dots either side of the line, where a stroked line would be a
        // pixel or two wide.
        #expect(try colors([ridge], z: 14, in: band(reach: 16, from: 6)).count > 1)
    }

    @Test("a breakwater is drawn in Carto's gray from zoom 12, as an area and as a line")
    func breakwaters() throws {
        let gray = VectorTileFixture.color("#AAAAAA")
        let mole = VectorTileFixture.Layer(name: VectorTileRasterizer.breakwatersLayer, features: [
            area("breakwater"),
        ])
        let groyne = VectorTileFixture.Layer(name: VectorTileRasterizer.breakwatersLayer, features: [
            line("groyne"),
        ])

        #expect(try colors([mole], z: 11, in: inside) == [land])
        #expect(try colors([mole], z: 12, in: inside) == [gray])
        #expect(try colors([groyne], z: 11, in: band(reach: 1)) == [land])
        #expect(try colors([groyne], z: 13, in: band(reach: 1)) == [gray])
    }

    // MARK: Trees

    @Test("a tree and a row of trees are drawn from zoom 16, in one green however they overlap")
    func trees() throws {
        let tree = VectorTileFixture.Feature(
            type: .point,
            properties: ["kind": .string("tree")],
            geometry: VectorTileFixture.points([(grid / 2, grid / 4), (grid / 2, grid / 4)])
        )
        let layer = VectorTileFixture.Layer(name: VectorTileRasterizer.treesLayer, features: [tree, line("tree_row")])
        let crown = CGRect(x: side / 2 - 1, y: side / 4 - 1, width: 2, height: 2)

        #expect(try colors([layer], z: 15, in: crown) == [land])
        #expect(try colors([layer], z: 15, in: band(reach: 1)) == [land])
        let dot = try colors([layer], z: 16, in: crown)
        let row = try colors([layer], z: 16, in: band(reach: 1))
        #expect(dot.count == 1)
        #expect(dot != [land])
        #expect(row == dot, "two trees on one spot are no darker than a row")
    }

    @Test("a tree has its trunk from zoom 18")
    func trunks() throws {
        let tree = VectorTileFixture.Feature(
            type: .point,
            properties: ["kind": .string("tree")],
            geometry: VectorTileFixture.points([(grid / 2, grid / 4)])
        )
        let layer = VectorTileFixture.Layer(name: VectorTileRasterizer.treesLayer, features: [tree])
        let trunk = CGRect(x: side / 2 - 1, y: side / 4 - 1, width: 2, height: 2)
        let crown = CGRect(x: side / 2 + 3, y: side / 4, width: 1, height: 1)

        #expect(try colors([layer], z: 17, in: trunk) == colors([layer], z: 17, in: crown))
        #expect(try colors([layer], z: 18, in: trunk) != colors([layer], z: 18, in: crown))
    }
}

// MARK: Seasonal stretches

extension VectorTileGroundTests {
    private func waterway(_ kind: String, _ points: [(Int, Int)]) -> VectorTileFixture.Feature {
        .init(type: .line, properties: ["kind": .string(kind)], geometry: VectorTileFixture.line(points))
    }

    /// A seasonal stream's gaps were once rubbed out of every waterway, and
    /// cut the river it crosses down the river's middle.
    @Test("a seasonal stream's gaps leave the river it crosses whole")
    func riverCrossedBySeasonalStream() throws {
        let river = waterway("river", [(grid / 2, grid / 8), (grid / 2, grid * 7 / 8)])
        let waterways = VectorTileFixture.Layer(name: "water", features: [line("stream"), river])
        let seasonal = VectorTileFixture.Layer(name: VectorTileRasterizer.intermittentLayer, features: [line("stream")])
        let riverMiddle = CGRect(x: side / 2 - 1, y: side / 4, width: 2, height: side / 2)

        #expect(try colors([waterways, seasonal], z: 14, in: riverMiddle) == [water])
        #expect(try colors([waterways, seasonal], z: 14, in: band(reach: 1)).contains(land), "the stream still broken")
    }

    /// The basemap joins a stream's pieces into one line, and can run it
    /// straight through the point where it starts to run all year.
    @Test("a stream is broken only along the stretch the extras say is not always there")
    func streamSeasonalForPartOfItsLength() throws {
        let stream = VectorTileFixture.Layer(name: "water", features: [line("stream")])
        let upper = waterway("stream", [(grid / 8, grid / 2), (grid / 2, grid / 2)])
        let seasonal = VectorTileFixture.Layer(name: VectorTileRasterizer.intermittentLayer, features: [upper])
        let along = band(reach: 1)
        let (left, right) = (
            CGRect(x: along.minX, y: along.minY, width: side / 4 - 16, height: along.height),
            CGRect(x: side / 2 + 16, y: along.minY, width: side / 4 - 16, height: along.height)
        )

        #expect(try colors([stream, seasonal], z: 14, in: left).contains(land))
        #expect(try colors([stream, seasonal], z: 14, in: right) == [water])
    }
}

// MARK: A boundary filed as a forest

extension VectorTileGroundTests {
    /// The basemap files a United States National Forest's boundary as a
    /// forest, and filled as one it painted trees over tundra and towns.
    /// Carto draws such a boundary as a border and no ground.
    @Test("a forest that is a protected area's boundary is neither filled nor given trees")
    func boundaryIsNoForest() throws {
        // Relation 91938915, as the basemap names it and as the extras' own layers do.
        let relation: UInt64 = 52_776_650_072_163
        let outlined: UInt64 = 919_389_153
        let forest = VectorTileFixture.Layer(name: "landuse", features: [area("forest", id: relation)])
        let outline = { (id: UInt64) in
            VectorTileFixture.Layer(name: VectorTileRasterizer.protectedAreasLayer, features: [
                VectorTileFixture.Feature(
                    type: .polygon,
                    properties: ["kind": .string("protected_area")],
                    geometry: VectorTileFixture.rectangle(x: 0...8, y: 0...8),
                    id: id
                ),
            ])
        }

        #expect(try colors([forest, outline(outlined)], z: 13, in: inside) == [land])
        let another = try colors([forest, outline(outlined + 10)], z: 13, in: inside)
        #expect(another.contains(wood))
        #expect(another.count > 1, "the trees")
    }
}
