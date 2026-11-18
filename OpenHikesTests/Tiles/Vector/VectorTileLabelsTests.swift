//
//  VectorTileLabelsTests.swift
//  OpenHikesTests
//
//  The names on a drawn tile: which features are named and in which language,
//  in what order they claim room, where each is placed, and that a name is
//  really drawn. Tiles are written by `VectorTileFixture`.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile labels")
struct VectorTileLabelsTests {
    private let tile = VectorTileAddress(z: 14, x: 8800, y: 5700)
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }

    private func point(
        _ properties: [String: VectorTileFixture.Value],
        at position: (Int, Int)? = nil
    ) -> VectorTileFixture.Feature {
        .init(
            type: .point,
            properties: properties,
            geometry: VectorTileFixture.points([position ?? (grid / 2, grid / 2)])
        )
    }

    private func candidates(
        _ layers: [VectorTileFixture.Layer],
        language: String = "en",
        at target: VectorTileAddress? = nil
    ) throws -> [VectorTileLabels.Candidate] {
        let decoded = try VectorTileFixture.decoded(layers, language: language)
        return VectorTileLabels.candidates(
            in: decoded,
            source: tile,
            target: target ?? tile,
            bounds: bounds,
            language: language,
            height: VectorTileFixture.height
        )
    }

    // MARK: Choosing

    @Test("a name is in the app's language where the map has it, and the local one where not")
    func nameInTheAppLanguage() throws {
        let vienna: [String: VectorTileFixture.Value] = [
            "kind": .string("locality"),
            "kind_detail": .string("city"),
            "name": .string("Wien"),
            "name:en": .string("Vienna"),
        ]
        let layers: [VectorTileFixture.Layer] = [.init(name: "places", features: [point(vienna)])]

        #expect(try candidates(layers, language: "en").map(\.name) == ["Vienna"])
        #expect(try candidates(layers, language: "fr").map(\.name) == ["Wien"], "no French name, so the local one")
    }

    @Test("summits, passes, huts, lakes, glaciers and places are named; benches and cafés are not")
    func whatIsNamed() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "places", features: [
                point(["kind": .string("locality"), "kind_detail": .string("village"), "name": .string("Gosau")]),
            ]),
            .init(name: "pois", features: [
                point(["kind": .string("peak"), "name": .string("Dachstein"), "elevation": .double(2995)]),
                point(["kind": .string("saddle"), "name": .string("Scharte"), "elevation": .double(2733)]),
                point(["kind": .string("alpine_hut"), "name": .string("Simonyhütte")]),
                point(["kind": .string("water"), "name": .string("Gosausee")]),
                point(["kind": .string("glacier"), "name": .string("Hallstätter Gletscher")]),
                point(["kind": .string("bench"), "name": .string("Rast")]),
                point(["kind": .string("restaurant"), "name": .string("Café")]),
                point(["kind": .string("peak")]),
            ]),
        ]

        let named = try candidates(layers)

        #expect(Set(named.map(\.name)) == [
            "Gosau", "Dachstein", "Scharte", "Simonyhütte", "Gosausee", "Hallstätter Gletscher",
        ])
        #expect(named.first { $0.name == "Dachstein" }?.detail == "2995 m", "a summit carries its height")
        #expect(named.first { $0.name == "Simonyhütte" }?.detail == nil)
    }

    /// The archive puts a name in a tile before the zoom it is meant for, and
    /// says which zoom that is.
    @Test("a name waits for its own minimum zoom")
    func minimumZoom() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "pois", features: [
                point(
                    ["kind": .string("peak"), "name": .string("Kogel"), "min_zoom": .double(15)],
                    at: (grid / 4, grid / 4)
                ),
            ]),
        ]
        // The quarter of the tile the summit stands in, a zoom deeper.
        let deeper = VectorTileAddress(z: tile.z + 1, x: tile.x * 2, y: tile.y * 2)

        #expect(try candidates(layers).isEmpty)
        #expect(try candidates(layers, at: deeper).map(\.name) == ["Kogel"])
    }

    /// Carto names a suburb from zoom 12, larger than a village, and the
    /// neighbourhoods inside it from zoom 15.
    @Test("a suburb is named before the neighbourhoods in it")
    func suburbBeforeNeighborhood() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "places", features: [
                point(
                    ["kind": .string("neighbourhood"), "kind_detail": .string("suburb"), "name": .string("Zugló")],
                    at: (grid / 8, grid / 8)
                ),
                point(
                    ["kind": .string("neighbourhood"), "kind_detail": .string("neighbourhood"), "name": .string("Rét")],
                    at: (grid / 4, grid / 4)
                ),
            ]),
        ]
        // The quarter of the tile both stand in, a zoom deeper.
        let deeper = VectorTileAddress(z: tile.z + 1, x: tile.x * 2, y: tile.y * 2)

        #expect(try candidates(layers).map(\.name) == ["Zugló"])
        #expect(try candidates(layers, at: deeper).map(\.name) == ["Zugló", "Rét"])
    }

    /// The archive offers a city from zoom 2 and the style sets one from
    /// zoom 4: a name with no size of its own would be set at Core Text's.
    @Test("a name waits for the first zoom its style sets it at")
    func styleZoom() throws {
        let decoded = try VectorTileFixture.decoded([
            .init(name: "places", features: [
                point(["kind": .string("locality"), "kind_detail": .string("city"), "name": .string("Wien")]),
            ]),
        ])
        let named = { (z: Int) in
            let target = VectorTileAddress(z: z, x: 0, y: 0)
            let found = VectorTileLabels.candidates(
                in: decoded,
                source: target,
                target: target,
                bounds: bounds,
                language: "en",
                height: VectorTileFixture.height
            )
            return found.map(\.name)
        }

        #expect(named(3).isEmpty)
        #expect(named(4) == ["Wien"])
    }

    /// The archive puts a lake's name on a point of the `water` layer, beside
    /// the points of rivers and fountains, and a pond's in `pois` as well.
    @Test("a lake is named from the water layer, once, and a river's or a fountain's point is not")
    func lakesFromTheWaterLayer() throws {
        let lake: [String: VectorTileFixture.Value] = [
            "kind": .string("water"),
            "kind_detail": .string("lake"),
            "name": .string("Hallstätter See"),
            "min_zoom": .double(12),
        ]
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "water", features: [
                point(lake, at: (grid / 4, grid / 4)),
                point(["kind": .string("water"), "kind_detail": .string("river"), "name": .string("Traun")]),
                point(["kind": .string("fountain"), "name": .string("Brunnen")], at: (grid / 4, grid * 3 / 4)),
                point(["kind": .string("water"), "name": .string("Teich")], at: (grid * 3 / 4, grid / 4)),
            ]),
            .init(name: "pois", features: [
                point(["kind": .string("water"), "name": .string("Teich")], at: (grid * 3 / 4, grid * 3 / 4)),
            ]),
        ]

        let named = try candidates(layers)

        #expect(named.map(\.name).sorted() == ["Hallstätter See", "Teich"])
        #expect(named.allSatisfy { $0.category == .water })
    }

    @Test("a point outside the tile is the neighbouring tile's to name")
    func pointsOutsideAreLeft() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "pois", features: [
                point(["kind": .string("peak"), "name": .string("Outside")], at: (grid + 20, grid / 2)),
            ]),
        ]

        #expect(try candidates(layers).isEmpty)
    }

    @Test("names claim room by what they name, then by size or height")
    func importanceOrder() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "places", features: [
                point(["kind": .string("locality"), "kind_detail": .string("hamlet"), "name": .string("Hamlet")]),
                point(town("Small Town", sortKey: 5)),
                point(town("Big Town", sortKey: -5)),
            ]),
            .init(name: "pois", features: [
                point(["kind": .string("peak"), "name": .string("Low"), "elevation": .double(1200)]),
                point(["kind": .string("peak"), "name": .string("High"), "elevation": .double(2900)]),
            ]),
        ]

        #expect(try candidates(layers).map(\.name) == ["Big Town", "Small Town", "High", "Low", "Hamlet"])
    }

    private func town(_ name: String, sortKey: Double) -> [String: VectorTileFixture.Value] {
        [
            "kind": .string("locality"),
            "kind_detail": .string("town"),
            "name": .string(name),
            "sort_key": .double(sortKey),
        ]
    }

    // MARK: Placing

    private func candidate(
        _ name: String,
        at anchor: CGPoint,
        _ category: VectorTileLabelStyle.Category = .town
    ) -> VectorTileLabels.Candidate {
        VectorTileLabels.Candidate(category: category, name: name, detail: nil, anchor: anchor, rank: 0)
    }

    private func place(_ candidates: [VectorTileLabels.Candidate], size: CGSize) -> [VectorTileLabels.Placement] {
        VectorTileLabels.place(
            candidates,
            sizes: Array(repeating: size, count: candidates.count),
            bounds: bounds,
            spacing: 4,
            markerClearance: 10
        )
    }

    @Test("where two names would overlap, the first keeps its place and the second goes")
    func overlapGoesToTheFirst() {
        let placed = place(
            [candidate("First", at: CGPoint(x: 200, y: 200)), candidate("Second", at: CGPoint(x: 220, y: 205))],
            size: CGSize(width: 80, height: 20)
        )

        #expect(placed.map(\.index) == [0])
    }

    /// A name never crosses a tile's edge, because the tile beside it could
    /// not finish it: it moves inward instead.
    @Test("a name near an edge is moved inside the tile")
    func nameMovesInsideTheEdge() throws {
        let placed = place([candidate("Edge", at: CGPoint(x: side - 5, y: 100))], size: CGSize(width: 80, height: 20))

        let frame = try #require(placed.first?.frame)
        #expect(frame.maxX <= side - 4)
        #expect(frame.minX >= 4)
    }

    @Test("a name too wide for any tile is left out")
    func tooWideIsLeftOut() {
        let placed = place([candidate("Wide", at: CGPoint(x: 256, y: 256))], size: CGSize(width: side, height: 20))

        #expect(placed.isEmpty)
    }

    @Test("a summit's name stands under its symbol, or over it when under is taken")
    func markerNameUnderThenOver() throws {
        let summit = CGPoint(x: 256, y: 256)
        let placed = place(
            [
                candidate("Below", at: CGPoint(x: 256, y: 286)),
                candidate("Summit", at: summit, .peak),
            ],
            size: CGSize(width: 60, height: 16)
        )

        let summitFrame = try #require(placed.first { $0.index == 1 }?.frame)
        #expect(summitFrame.maxY <= summit.y, "under was taken by the town, so the summit's name went over")
    }

    // MARK: Drawing

    @Test("a name is drawn in ink over the map")
    func nameIsDrawn() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "earth", features: [
                .init(
                    type: .polygon,
                    properties: ["kind": .string("earth")],
                    geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
                ),
            ]),
            .init(name: "places", features: [
                point(["kind": .string("locality"), "kind_detail": .string("town"), "name": .string("Hallstatt")]),
            ]),
        ]
        let unnamed = [layers[0]]

        #expect(try darkPixels(layers) > 0)
        #expect(try darkPixels(unnamed) == 0)
    }

    /// Pixels near the middle darker than any fill the style uses: the ink of
    /// a name.
    private func darkPixels(_ layers: [VectorTileFixture.Layer]) throws -> Int {
        let decoded = try VectorTileFixture.decoded(layers)
        let image = try #require(VectorTileRasterizer.image(
            of: decoded,
            from: tile,
            drawing: tile,
            language: "en",
            height: VectorTileFixture.height
        ))
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
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
        let middle = width / 2
        let reach = width / 8
        let ink = 100
        var count = 0
        for y in (middle - reach)..<(middle + reach) {
            for x in (middle - reach)..<(middle + reach) where Int(pixels[(y * width + x) * 4]) < ink {
                count += 1
            }
        }
        return count
    }
}
