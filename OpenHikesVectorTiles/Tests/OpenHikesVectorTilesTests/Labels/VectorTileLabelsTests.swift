//
//  VectorTileLabelsTests.swift
//  OpenHikesVectorTilesTests
//
//  The names on a drawn tile: which features are named and in which language,
//  in what order they claim room, where each is placed, and that a name is
//  really drawn. Tiles are written by `VectorTileFixture`.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
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
            language: language
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

    /// Summits, huts and every other point are drawn with their icons, and
    /// named under them, by `VectorTilePoints`.
    @Test("places, lakes and glaciers are named here; summits, huts and cafés are left to the points")
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

        #expect(Set(named.map(\.name)) == ["Gosau", "Gosausee", "Hallstätter Gletscher"])
    }

    /// The archive puts a name in a tile before the zoom it is meant for, and
    /// says which zoom that is.
    @Test("a name waits for its own minimum zoom")
    func minimumZoom() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "places", features: [
                point(
                    [
                        "kind": .string("locality"),
                        "kind_detail": .string("hamlet"),
                        "name": .string("Kogel"),
                        "min_zoom": .double(15),
                    ],
                    at: (grid / 4, grid / 4)
                ),
            ]),
        ]
        // The quarter of the tile the hamlet stands in, a zoom deeper.
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
                language: "en"
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
            .init(name: "places", features: [
                point(town("Outside", sortKey: 0), at: (grid + 20, grid / 2)),
            ]),
        ]

        #expect(try candidates(layers).isEmpty)
    }

    @Test("names claim room by what they name, then by size")
    func importanceOrder() throws {
        let layers: [VectorTileFixture.Layer] = [
            .init(name: "places", features: [
                point(["kind": .string("locality"), "kind_detail": .string("hamlet"), "name": .string("Hamlet")]),
                point(town("Small Town", sortKey: 5)),
                point(town("Big Town", sortKey: -5)),
            ]),
        ]

        #expect(try candidates(layers).map(\.name) == ["Big Town", "Small Town", "Hamlet"])
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
        VectorTileLabels.Candidate(category: category, name: name, anchor: anchor, rank: 0)
    }

    private func place(_ candidates: [VectorTileLabels.Candidate], size: CGSize) -> [VectorTileLabels.Placement] {
        VectorTileLabels.place(
            candidates,
            sizes: Array(repeating: size, count: candidates.count),
            bounds: bounds,
            spacing: 4
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

    /// CoreText reads a stroke of no width as a fill in its default black,
    /// and Carto sets a private car park's name with no halo.
    @Test("a name with no halo is drawn in its ink alone, with nothing black under it")
    func noHaloDrawsNoOutline() {
        let canvas = 64
        var fonts = LabelFonts(language: "en")
        let font = fonts.font(size: 20, face: .regular)
        let cyan = VectorTileStyle.color("#00FFFF")
        let name = InkedText("Wg", font: font, color: cyan, unit: 1, haloWidth: 0)
        var bytes = [UInt8](repeating: 0, count: canvas * canvas * 4)

        bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: canvas,
                      height: canvas,
                      bitsPerComponent: 8,
                      bytesPerRow: canvas * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.setFillColor(VectorTileStyle.color("#FFFFFF"))
            context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
            let baseline = CGPoint(x: 8, y: 24)
            name.drawHalo(at: baseline, context: context)
            name.drawInk(at: baseline, context: context)
        }

        let red = stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
        let green = stride(from: 1, to: bytes.count, by: 4).map { bytes[$0] }
        #expect(red.contains { $0 < 100 })
        #expect(green.allSatisfy { $0 >= 255 - 3 })
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

// MARK: Localities, bays and long names

extension VectorTileLabelsTests {
    private func place(_ detail: String, _ name: String) -> VectorTileFixture.Feature {
        point(["kind": .string("locality"), "kind_detail": .string(detail), "name": .string(name)])
    }

    private func categories(at z: Int) throws -> [VectorTileLabelStyle.Category] {
        let places = [place("hamlet", "Hinterbrand"), place("farm", "Schapbachhof"), place("locality", "Kessel")]
        let layers: [VectorTileFixture.Layer] = [.init(name: "places", features: places)]
        let address = VectorTileAddress(z: z, x: 0, y: 0)
        let decoded = try VectorTileFixture.decoded(layers)
        return VectorTileLabels
            .candidates(in: decoded, source: address, target: address, bounds: bounds, language: "en")
            .map(\.category)
    }

    /// Ben Nevis carried two dozen gully names at zoom 13, and two summits
    /// lost theirs to them.
    @Test("a hamlet is named from zoom 14, a farm from 15 and a locality from 16")
    func smallPlacesWait() throws {
        #expect(try categories(at: 13).isEmpty)
        #expect(try categories(at: 14) == [.hamlet])
        #expect(try categories(at: 15) == [.hamlet, .dwelling])
        #expect(try categories(at: 16) == [.hamlet, .dwelling, .locality])
    }

    @Test("a locality waits for every point's name, a lake and a glacier for the summits', and a place for nothing")
    func whenANameClaimsItsRoom() {
        #expect(VectorTileLabelStyle.Category.locality.turn == .afterPoints)
        #expect(VectorTileLabelStyle.Category.water.turn == .afterSummits)
        #expect(VectorTileLabelStyle.Category.glacier.turn == .afterSummits)
        #expect(VectorTileLabelStyle.Category.hamlet.turn == .first)
        #expect(VectorTileLabelStyle.Category.town.turn == .first)
    }

    @Test("a name keeps clear of the room taken before it")
    func nameKeepsClearOfTakenRoom() {
        let spot = CGPoint(x: 256, y: 256)
        let name = [VectorTileLabels.Candidate(category: .locality, name: "Kessel", anchor: spot, rank: 0)]
        let size = [CGSize(width: 80, height: 20)]

        let free = VectorTileLabels.place(name, sizes: size, bounds: bounds, spacing: 4)
        let taken = VectorTileLabels.place(
            name,
            sizes: size,
            bounds: bounds,
            spacing: 4,
            occupied: [CGRect(x: 250, y: 250, width: 12, height: 12)]
        )

        #expect(free.count == 1)
        #expect(taken.isEmpty)
    }

    @Test("a bay and a strait are named as a lake is; a sea is not")
    func baysAndStraits() {
        typealias Category = VectorTileLabelStyle.Category
        #expect(Category.water(kind: "bay", detail: nil) == .water)
        #expect(Category.water(kind: "strait", detail: nil) == .water)
        #expect(Category.water(kind: "water", detail: "lake") == .water)
        #expect(Category.water(kind: "sea", detail: nil) == nil)
        #expect(Category.water(kind: "ocean", detail: nil) == nil)
        #expect(Category.water(kind: "water", detail: "river") == nil)
        #expect(Category.poi(kind: "bay") == .water)
    }

    @Test("a lake's name grows with the zooms since the archive first offered it, a pond's less")
    func waterSizes() {
        let lake = (0...3).map { VectorTileLabelStyle.waterSize(zoomsPastFirst: $0, firstZoom: 10) }
        let pond = (0...3).map { VectorTileLabelStyle.waterSize(zoomsPastFirst: $0, firstZoom: 15) }

        #expect(lake == [10, 12, 15, 15])
        #expect(pond == [10, 12, 12, 12])
        #expect(VectorTileLabelStyle.waterSize(zoomsPastFirst: -1, firstZoom: 10) == 10)
    }

    @Test("a lake offered since two zooms back is a candidate with the larger size")
    func lakeCandidateSize() throws {
        let first = VectorTileFixture.Value.double(Double(tile.z - 2))
        let lake = point(["kind": .string("water"), "name": .string("Königssee"), "min_zoom": first])
        let layers: [VectorTileFixture.Layer] = [.init(name: "water", features: [lake])]

        #expect(try candidates(layers).map(\.size) == [15])
    }

    /// “Saalfelden am Steinernen Meer” was one line, half a tile wide.
    @Test("a long name takes less width and more height than its one line would")
    func longNameIsBroken() throws {
        let spot = CGPoint(x: 256, y: 256)
        let long = [candidate("Saalfelden am Steinernen Meer", at: spot)]
        let short = [candidate("Saalfelden", at: spot)]

        let broken = try #require(layout(long).placements.first?.frame)
        let one = try #require(layout(short).placements.first?.frame)

        #expect(broken.height > one.height * 1.5, "two lines or three")
        #expect(broken.width < one.width * 2)
    }

    private func layout(_ candidates: [VectorTileLabels.Candidate]) -> VectorTileLabels.Layout {
        VectorTileLabels.Layout(candidates, z: 12, unit: 2, bounds: bounds, language: "en")
    }
}
