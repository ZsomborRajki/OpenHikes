//
//  VectorTileAreaEdgeNamesTests.swift
//  OpenHikesTests
//
//  A protected area's name along the inside of its edge, as OpenStreetMap
//  Carto writes it: which areas are named at which zoom, that the name stands
//  on the area's side of the edge however it reads, and that it is drawn in
//  the border's color. How the tiles share an edge between them is
//  `VectorTileAreaEdgeTilingTests`. Tiles are written by `VectorTileFixture`.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile area edge names")
struct VectorTileAreaEdgeNamesTests {
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private var frame: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    /// An area's size in the extras' unit, the square pixels of the world as
    /// one 256-pixel tile, that covers `pixels` at zoom `z`.
    private func size(_ pixels: Double, atZ z: Int) -> Double {
        pixels / pow(4, Double(z))
    }

    // MARK: Choosing

    /// Carto names an area along its edge from zoom 13 once it covers
    /// 192,000 square pixels, so an area too small at 13 is named from the
    /// zoom it grows past that.
    @Test("an area is named along its edge from zoom 13, once it covers 192,000 square pixels")
    func namedBySize() throws {
        let large = area("Triglavski narodni park", size: size(250_000, atZ: 13))
        let small = area("Blejski vintgar", size: size(100_000, atZ: 13))
        let tile = try protectedAreas([large, small])

        #expect(names(in: tile, z: 12).isEmpty, "no area is named along its edge before zoom 13")
        #expect(names(in: tile, z: 13) == ["Triglavski narodni park"])
        #expect(names(in: tile, z: 14) == ["Blejski vintgar", "Triglavski narodni park"])
    }

    /// The archive goes to zoom 15, and an offline download without Extra
    /// Detail to zoom 14, and every deeper zoom is drawn from the deepest
    /// there is, where an area covers four times as much at each zoom.
    @Test("the size is read at the zoom drawn, deeper than the archive goes", arguments: [14, 15])
    func sizeAtTheZoomDrawn(archiveZ: Int) throws {
        let tile = try protectedAreas([area("Naturschutzgebiet", size: size(50_000, atZ: archiveZ))])
        let archive = VectorTileAddress(z: archiveZ, x: 0, y: 0)

        let atArchive = VectorTileLineLabels.areaEdges(in: tile, source: archive, target: archive, language: "de")
        let deeper = VectorTileLineLabels.areaEdges(
            in: tile,
            source: archive,
            target: VectorTileAddress(z: archiveZ + 1, x: 0, y: 0),
            language: "de"
        )

        #expect(atArchive.isEmpty, "50,000 square pixels at the archive's zoom")
        #expect(!deeper.isEmpty, "200,000 a zoom deeper")
    }

    /// Extras built before the edges were named give no area its size or
    /// its names, and the extras give a smaller area neither before its
    /// zoom.
    @Test("an area without a size or a name is not named")
    func withoutSizeOrName() throws {
        var unsized = area("Kalkhochalpen", size: 1)
        unsized.properties["area"] = nil
        var unnamed = area("", size: 1)
        unnamed.properties["name"] = nil
        let tile = try protectedAreas([unsized, unnamed])

        #expect(names(in: tile, z: 13).isEmpty)
    }

    @Test("aboriginal lands are named in their border's brown, every other protected area in its green")
    func colors() throws {
        let lands = area("Uluṟu-Kata Tjuṯa", size: 1, kind: "aboriginal_lands")
        let tile = try protectedAreas([lands, area("Kakadu", size: 1)])
        let address = VectorTileAddress(z: 13, x: 0, y: 0)

        let lines = VectorTileLineLabels.areaEdges(in: tile, source: address, target: address, language: "en")

        #expect(lines.first { $0.name == "Uluṟu-Kata Tjuṯa" }?.category == .aboriginalLands)
        #expect(lines.first { $0.name == "Kakadu" }?.category == .protectedArea)
        let brown = VectorTileStyle.protectedBorder(kind: "aboriginal_lands").color
        let green = VectorTileStyle.protectedBorder(kind: "protected_area").color
        #expect(VectorTileLabelStyle.look(of: .aboriginalLands).color == brown)
        #expect(VectorTileLabelStyle.look(of: .protectedArea).color == green)
        #expect(brown != green)
    }

    /// Carto's `protected-areas-text` comes after its waterways' names.
    @Test("an area's name is placed after the points' and the water's")
    func placedAfterWater() {
        #expect(VectorTileLabelStyle.LineCategory.protectedArea.isPlacedAfterPoints)
        #expect(VectorTileLabelStyle.LineCategory.ditch < .protectedArea)
    }

    // MARK: The extras' schema

    /// The archive gives an area its size and names from zoom 13 if it is
    /// large enough by the map's own figure to be named along its edge
    /// then, and every area both at zoom 14, which an offline download
    /// without Extra Detail draws every deeper zoom from, in every language
    /// the extras keep names in. The map reads the layer's buffer as the
    /// place the archive cuts an area.
    @Test("the extras give an area its size and names from the zoom it is named along its edge")
    func schemaGivesSizeAndNames() throws {
        let schema = try String(
            contentsOf: StringCatalogTests.sourceRoot.appending(path: "Scripts/lib/vector-extras.yml"),
            encoding: .utf8
        )
        let layer = try #require(
            schema.components(separatedBy: "- id: \(VectorTileRasterizer.protectedAreasLayer)\n").last
        )
        .components(separatedBy: "\n- id: ")[0]
        let languages = schema.split(separator: "\n")
            .filter { $0.hasPrefix("    key: 'name:") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let firstZoom = VectorTileLineLabels.areaEdgeZ
        let scale = Int(pow(4, Double(firstZoom)))

        #expect(layer.contains("* \(scale).0 > \(VectorTileLineLabels.areaEdgeSize) }'\n        value: \(firstZoom)"))
        #expect(layer.contains("value: \(firstZoom)\n      - else: \(VectorTileLineLabels.areaEdgeEveryAreaZ)\n"))
        #expect(layer.hasPrefix("  buffer: \(Int(VectorTileLineLabels.areaEdgeBuffer))\n"))
        #expect(layer.contains("- key: area\n"))
        #expect(layer.contains("- key: name\n      min_zoom: *edge_name_zoom"))
        #expect(languages.count > 1)
        for language in languages {
            #expect(layer.contains("- \(language)\n      tag_value:"), "\(language)")
        }
    }

    // MARK: Placing and drawing

    /// The archive winds a ring with the area on its right, so the top of a
    /// ring runs rightward with the area below it and the bottom leftward
    /// with the area above. A stream's name goes below the name either way.
    @Test("the name stands inside the area, whichever way its edge runs")
    func nameInsideTheArea() throws {
        let east = [CGPoint(x: 0, y: 256), CGPoint(x: side, y: 256)]
        let west = [CGPoint(x: side, y: 256), CGPoint(x: 0, y: 256)]

        let rightward = try #require(nameMiddle(.protectedArea, along: east))
        let leftward = try #require(nameMiddle(.protectedArea, along: west))
        let stream = try #require(nameMiddle(.stream, along: west))

        #expect(rightward - 256 > 10, "below a top edge")
        #expect(256 - leftward > 10, "above a bottom edge")
        #expect(stream > 256, "a stream's name is below it whichever way it runs")
    }

    @Test("an area's name is drawn in its border's color, and not without one")
    func nameIsDrawn() throws {
        let named = try image(area("Triglavski narodni park", size: size(250_000, atZ: 13)))
        let unnamed = try image(area("Triglavski narodni park", size: size(100_000, atZ: 13)))
        let lands = try image(area("Kakadu", size: size(250_000, atZ: 13), kind: "aboriginal_lands"))

        #expect(VectorTileFixture.image(named, has: "#008000"))
        #expect(!VectorTileFixture.image(unnamed, has: "#008000"), "the border alone is fainter than a letter")
        #expect(VectorTileFixture.image(lands, has: "#82643A"))
    }

    // MARK: Helpers

    /// A protected area over the middle of the tile, wound as the archive
    /// winds one.
    private func area(_ name: String, size: Double, kind: String = "protected_area") -> VectorTileFixture.Feature {
        .init(
            type: .polygon,
            properties: ["kind": .string(kind), "name": .string(name), "area": .double(size)],
            geometry: VectorTileFixture.rectangle(x: grid / 8...grid * 7 / 8, y: grid / 8...grid * 7 / 8)
        )
    }

    private func protectedAreas(_ features: [VectorTileFixture.Feature]) throws -> MapboxVectorTile {
        try VectorTileFixture.decoded([.init(name: VectorTileRasterizer.protectedAreasLayer, features: features)])
    }

    private func names(in tile: MapboxVectorTile, z: Int) -> [String] {
        let address = VectorTileAddress(z: z, x: 0, y: 0)
        let lines = VectorTileLineLabels.lines(in: tile, source: address, target: address, language: "sl")
        return Set(lines.map(\.name)).sorted()
    }

    /// The middle height of a name set along `points` at zoom 13, on a tile
    /// the world's grid crosses most of the way across.
    private func nameMiddle(_ category: VectorTileLabelStyle.LineCategory, along points: [CGPoint]) -> CGFloat? {
        let line = VectorTileLineLabels.NamedLine(category: category, name: "Narodni park", points: points)
        let layout = VectorTileLineLabels.Layout(
            [line],
            target: VectorTileAddress(z: 13, x: 2, y: 0),
            unit: 2,
            bounds: frame,
            occupied: [],
            language: "sl"
        )
        let boxes = layout.taken
        return boxes.isEmpty ? nil : boxes.map(\.midY).reduce(0, +) / CGFloat(boxes.count)
    }

    private func image(_ feature: VectorTileFixture.Feature) throws -> CGImage {
        let address = VectorTileAddress(z: 13, x: 4400, y: 2900)
        let land = VectorTileFixture.Layer(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
        let layers = [land, .init(name: VectorTileRasterizer.protectedAreasLayer, features: [feature])]
        return try #require(try VectorTileFixture.image(layers, from: address, drawing: address))
    }
}
