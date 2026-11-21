//
//  VectorTileBuildingNamesTests.swift
//  OpenHikesVectorTilesTests
//
//  The names of buildings on a drawn tile, read from tiles written by
//  `VectorTileFixture`: which buildings are named at each zoom, by their
//  size, in whose language, and that a building named for the shop or the
//  hut in it leaves its name to that point.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
import Testing

@Suite("Vector tile building names")
struct VectorTileBuildingNamesTests {
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize

    private func tile(z: Int) -> VectorTileAddress {
        VectorTileAddress(z: z, x: 1 << (z - 1), y: 1 << (z - 1))
    }

    /// A named building's point, of `pixels` square pixels at zoom 14.
    private func building(
        _ name: String,
        pixels: Double,
        at spot: (Int, Int)? = nil,
        german: String? = nil
    ) -> VectorTileFixture.Feature {
        var properties: [String: VectorTileFixture.Value] = [
            "name": .string(name),
            VectorTilePoints.sizeKey: .double(pixels / pow(4, Double(VectorTileBuildingNames.minimumZ))),
        ]
        if let german { properties["name:de"] = .string(german) }
        return .init(
            type: .point,
            properties: properties,
            geometry: VectorTileFixture.points([spot ?? (grid / 2, grid / 2)])
        )
    }

    private func names(
        _ buildings: [VectorTileFixture.Feature],
        z: Int,
        language: String = "en",
        besides points: [VectorTilePoints.Candidate] = []
    ) throws -> [VectorTilePoints.Candidate] {
        let layer = VectorTileFixture.Layer(name: VectorTileBuildingNames.layerName, features: buildings)
        let source = tile(z: min(z, 15))
        let shift = z - source.z
        return VectorTileBuildingNames.candidates(
            in: try VectorTileFixture.decoded([layer], language: language),
            source: source,
            target: VectorTileAddress(z: z, x: source.x << shift, y: source.y << shift),
            language: language,
            besides: points
        )
    }

    private func point(named name: String, at anchor: CGPoint) -> VectorTilePoints.Candidate {
        VectorTilePoints.Candidate(
            anchor: anchor,
            lines: [name],
            look: VectorTileBuildingNames.look,
            rank: VectorTilePoints.Rank(
                order: 0,
                height: -.infinity,
                minimumZoom: 15,
                name: name,
                x: anchor.x,
                y: anchor.y
            )
        )
    }

    // MARK: Choosing

    /// Carto names a building from zoom 14 once it covers 3,000 square
    /// pixels, which each zoom deeper makes four times as easy. A zoom past
    /// 15 is drawn from the zoom-15 tile around it, here from its first
    /// corner.
    @Test("a building is named once it covers 3,000 square pixels, and not before zoom 14")
    func bySize() throws {
        let hall = building("Messehalle", pixels: 3200)
        let barn = building("Stadel", pixels: 800)

        #expect(try names([hall, barn], z: 13).isEmpty)
        #expect(try names([hall, barn], z: 14).map(\.lines) == [["Messehalle"]])
        #expect(try names([hall, barn], z: 15).map(\.lines) == [["Messehalle"], ["Stadel"]])
    }

    @Test("every named building is named from zoom 17, the larger first")
    func everyBuildingFromZoom17() throws {
        let shed = building("Schuppen", pixels: 1, at: (grid / 16, grid / 16))
        let hall = building("Messehalle", pixels: 3200, at: (grid / 8, grid / 8))

        #expect(try names([shed, hall], z: 16).map(\.lines) == [["Messehalle"]])
        #expect(try names([shed, hall], z: 17).map(\.lines) == [["Messehalle"], ["Schuppen"]])
    }

    @Test("a building is named in the reader's language where the tile has it, and a point beyond the tile is not")
    func languageAndBounds() throws {
        let castle = building("Hrad", pixels: 4000, german: "Burg")
        let beyond = building("Zámek", pixels: 4000, at: (grid + grid / 8, grid / 2))

        #expect(try names([castle, beyond], z: 14, language: "de").map(\.lines) == [["Burg"]])
        #expect(try names([castle, beyond], z: 14).map(\.lines) == [["Hrad"]])
        #expect(try names([castle], z: 14).first?.anchor == CGPoint(x: side / 2, y: side / 2))
    }

    @Test("a building with no name, or with no size before zoom 17, is not named")
    func unnamedAndUnsized() throws {
        let unnamed = VectorTileFixture.Feature(
            type: .point,
            properties: [VectorTilePoints.sizeKey: .double(1)],
            geometry: VectorTileFixture.points([(grid / 2, grid / 2)])
        )
        let unsized = VectorTileFixture.Feature(
            type: .point,
            properties: ["name": .string("Stadel")],
            geometry: VectorTileFixture.points([(grid / 8, grid / 8)])
        )

        #expect(try names([unnamed, unsized], z: 15).isEmpty)
        #expect(try names([unnamed, unsized], z: 17).map(\.lines) == [["Stadel"]])
    }

    // MARK: The point in the building

    /// A hut's building carries the hut's name, and the hut's own point is
    /// already named under its icon.
    @Test("a building leaves its name to a point of the same name standing by it")
    func sameNameNearby() throws {
        let middle = CGPoint(x: side / 2, y: side / 2)
        let near = CGPoint(x: middle.x + VectorTileBuildingNames.reach * unit / 2, y: middle.y)
        let far = CGPoint(x: middle.x + VectorTileBuildingNames.reach * unit * 2, y: middle.y)
        let hut = building("Kredarica", pixels: 4000)

        #expect(try names([hut], z: 15, besides: [point(named: "Kredarica", at: near)]).isEmpty)
        #expect(try names([hut], z: 15, besides: [point(named: "Kredarica", at: far)]).count == 1)
        #expect(try names([hut], z: 15, besides: [point(named: "Planika", at: near)]).count == 1)
    }

    // MARK: The look

    @Test("a building's name is written in Carto's dark gray, with no icon, and after the points' own")
    func look() throws {
        let text = try #require(VectorTileBuildingNames.look.text)

        #expect(text.size == 11)
        #expect(text.color == VectorTileStyle.color("#444444"))
        #expect(text.offset == 0)
        #expect(VectorTileBuildingNames.look.icons.isEmpty)
        #expect(!VectorTileBuildingNames.look.lowPriority)
    }

    @Test("a building's name is drawn on the map, and gives way to a point's name on its spot")
    func drawnAfterThePoints() throws {
        let ink = "#444444"
        let earth = VectorTileFixture.Layer(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
        let hall = VectorTileFixture.Layer(
            name: VectorTileBuildingNames.layerName,
            features: [building("Messehalle", pixels: 4000)]
        )
        let summit = VectorTileFixture.Layer(name: "pois", features: [
            .init(
                type: .point,
                properties: ["kind": .string("peak"), "name": .string("Hochwanner"), "elevation": .double(2744)],
                geometry: VectorTileFixture.points([(grid / 2, grid / 2 - grid / 32)])
            ),
        ])
        let address = tile(z: 15)

        let alone = try #require(try VectorTileFixture.image([earth, hall], from: address, drawing: address))
        let crowded = try #require(try VectorTileFixture.image([earth, hall, summit], from: address, drawing: address))

        #expect(VectorTileFixture.image(alone, has: ink, tolerance: 24))
        #expect(!VectorTileFixture.image(crowded, has: ink, tolerance: 24))
    }
}
