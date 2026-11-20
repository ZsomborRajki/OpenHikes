//
//  VectorTilePatternsTests.swift
//  OpenHikesTests
//
//  The pictures Carto fills an area with: which one an area of each kind
//  takes and from which zoom, that every one named is in the asset catalog
//  and none is there unnamed, that a picture is laid from the corner of the
//  world so two tiles carry one pattern across their edge, and a cliff's
//  teeth down the side that falls away.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Vector tile patterns")
struct VectorTilePatternsTests {
    private let side = VectorTileRasterizer.pixelSize
    private let unit = CGFloat(VectorTileRasterizer.pixelSize) / VectorTileRasterizer.styleTileSize
    private let deepest = 20

    private func asset(_ name: String) -> String {
        VectorTilePatterns.assetPrefix + name
    }

    // MARK: Which pattern

    @Test("a wood has trees by its leaves from zoom 13, and the trees of unknown leaves where nobody said")
    func woods() throws {
        #expect(VectorTilePatterns.symbols(kind: "wood", detail: "mixed", z: 12) == nil)
        #expect(VectorTilePatterns.symbols(kind: "wood", detail: nil, z: 13)?.asset == asset("leaftype_unknown"))
        #expect(VectorTilePatterns.symbols(kind: "forest", detail: "mixed", z: 13)?.asset == asset("leaftype_mixed"))
        #expect(VectorTilePatterns.symbols(kind: "wood", detail: "palm", z: 13)?.asset == asset("leaftype_unknown"))

        let trees = try #require(VectorTilePatterns.symbols(kind: "wood", detail: "needleleaved", z: 15))
        #expect(trees.asset == asset("leaftype_needleleaved"))
        #expect(trees.opacity == VectorTilePatterns.woodOpacity)
        #expect(trees.solid.opacity == 1)
        #expect(trees.solid.asset == trees.asset)
    }

    @Test("a wetland has the plain marks from zoom 10, and its own kind's from 13", arguments: [
        ("marsh", "wetland_marsh"), ("saltmarsh", "wetland_marsh"), ("wet_meadow", "wetland_marsh"),
        ("reedbed", "wetland_reed"), ("mangrove", "wetland_mangrove"), ("swamp", "wetland_swamp"),
        ("bog", "wetland_bog"), ("fen", "wetland_bog"), ("string_bog", "wetland_bog"), ("tidalflat", "wetland"),
    ])
    func wetlands(detail: String, name: String) {
        #expect(VectorTilePatterns.symbols(kind: "wetland", detail: detail, z: 9) == nil)
        #expect(VectorTilePatterns.symbols(kind: "wetland", detail: detail, z: 10)?.asset == asset("wetland"))
        #expect(VectorTilePatterns.symbols(kind: "wetland", detail: detail, z: 13)?.asset == asset(name))
        #expect(VectorTilePatterns.symbols(kind: "wetland", detail: nil, z: 13)?.asset == asset("wetland"))
    }

    @Test("mud has a wetland's plain marks, scrub and a salt pond their own, and a reef its own from zoom 10")
    func otherSymbols() {
        #expect(VectorTilePatterns.symbols(kind: "mud", detail: nil, z: 13)?.asset == asset("wetland"))
        #expect(VectorTilePatterns.symbols(kind: "scrub", detail: nil, z: 12) == nil)
        #expect(VectorTilePatterns.symbols(kind: "scrub", detail: nil, z: 13)?.asset == asset("scrub"))
        #expect(VectorTilePatterns.symbols(kind: "salt_pond", detail: nil, z: 13)?.asset == asset("salt_pond"))
        #expect(VectorTilePatterns.symbols(kind: "reef", detail: nil, z: 9) == nil)
        #expect(VectorTilePatterns.symbols(kind: "reef", detail: nil, z: 10)?.asset == asset("reef"))
        #expect(VectorTilePatterns.symbols(kind: "meadow", detail: nil, z: deepest) == nil)
    }

    /// Carto marks a beach only where its surface is mapped.
    @Test("a beach is dotted by its surface, and one of no known surface not at all")
    func beaches() {
        #expect(VectorTilePatterns.symbols(kind: "beach", detail: nil, z: 15) == nil)
        #expect(VectorTilePatterns.symbols(kind: "beach", detail: "sand", z: 12) == nil)
        #expect(VectorTilePatterns.symbols(kind: "beach", detail: "sand", z: 13)?.asset == asset("beach"))
        #expect(VectorTilePatterns.symbols(kind: "shoal", detail: "pebbles", z: 13)?.asset == asset("beach_coarse"))
        #expect(VectorTilePatterns.symbols(kind: "beach", detail: "concrete", z: 15) == nil)
    }

    @Test("the patterns over a fill: each kind's own, from Carto's zoom", arguments: [
        ("quarry", 10, "quarry"), ("vineyard", 13, "vineyard"), ("orchard", 13, "orchard"),
        ("plant_nursery", 13, "plant_nursery"), ("garden", 13, "plant_nursery"), ("allotments", 13, "allotments"),
        ("dog_park", 16, "dog_park"), ("bare_rock", 13, "rock_overlay"), ("scree", 13, "scree_overlay"),
        ("shingle", 13, "scree_overlay"),
    ])
    func overFill(kind: String, firstZ: Int, name: String) {
        #expect(VectorTilePatterns.ground(kind: kind, detail: nil, z: firstZ - 1) == nil)
        #expect(VectorTilePatterns.ground(kind: kind, detail: nil, z: firstZ)?.asset == asset(name))
        #expect(VectorTilePatterns.symbols(kind: kind, detail: nil, z: deepest) == nil)
    }

    @Test("a garden's pattern is fainter than a nursery's, and a kind with no pattern has none")
    func gardensAndOthers() throws {
        let garden = try #require(VectorTilePatterns.ground(kind: "garden", detail: nil, z: 13))
        let nursery = try #require(VectorTilePatterns.ground(kind: "plant_nursery", detail: nil, z: 13))

        #expect(garden.opacity < nursery.opacity)
        #expect(VectorTilePatterns.ground(kind: "wood", detail: nil, z: deepest) == nil)
        #expect(VectorTilePatterns.ground(kind: "residential", detail: nil, z: deepest) == nil)
    }

    @Test("a cemetery has the graves of its religion from zoom 13, and plain ones for any other")
    func cemeteries() {
        let graves = { (kind: String, religion: String?, z: Int) in
            VectorTilePatterns.ground(kind: kind, detail: religion, z: z)?.asset
        }

        #expect(graves("cemetery", "jewish", 12) == nil)
        #expect(graves("cemetery", "jewish", 13) == asset("grave_yard_jewish"))
        #expect(graves("grave_yard", "christian", 13) == asset("grave_yard_christian"))
        #expect(graves("cemetery", "muslim", 13) == asset("grave_yard_muslim"))
        #expect(graves("cemetery", "buddhist", 13) == asset("grave_yard_generic"))
        #expect(graves("cemetery", nil, 13) == asset("grave_yard_generic"))
    }

    @Test("a ridge's and an arête's dots are closer from zoom 15, and a danger area's hatch is its own")
    func linesAndHatches() {
        #expect(VectorTilePatterns.ridge(kind: "ridge", z: 14).asset == asset("ridge-mid"))
        #expect(VectorTilePatterns.ridge(kind: "ridge", z: 15).asset == asset("ridge2"))
        #expect(VectorTilePatterns.ridge(kind: "arete", z: 14).asset == asset("arete-mid"))
        #expect(VectorTilePatterns.ridge(kind: "arete", z: 15).asset == asset("arete2"))
        #expect(VectorTilePatterns.hatch(kind: "military").asset == asset("military_red_hatch"))
        #expect(VectorTilePatterns.hatch(kind: "danger_area").asset == asset("danger_red_hatch"))
    }

    // MARK: The catalog

    /// Every picture the tables can name, over every kind and detail Carto
    /// tells apart.
    private var named: Set<String> {
        let details: [String?] = [
            nil, "christian", "jewish", "muslim", "broadleaved", "needleleaved", "mixed", "leafless", "marsh",
            "reedbed", "mangrove", "swamp", "bog", "sand", "gravel",
        ]
        let kinds = [
            "quarry", "vineyard", "orchard", "plant_nursery", "garden", "allotments", "dog_park", "bare_rock", "scree",
            "shingle", "cemetery", "grave_yard", "wood", "forest", "wetland", "mud", "beach", "shoal", "reef", "scrub",
            "salt_pond",
        ]
        var found: Set<String> = [VectorTilePatterns.intermittentWater.asset]
        for kind in kinds {
            for detail in details {
                for z in [VectorTilePatterns.wideZ, deepest] {
                    if let pattern = VectorTilePatterns.ground(kind: kind, detail: detail, z: z) {
                        found.insert(pattern.asset)
                    }
                    if let pattern = VectorTilePatterns.symbols(kind: kind, detail: detail, z: z) {
                        found.insert(pattern.asset)
                    }
                }
            }
        }
        for kind in ["ridge", "arete"] {
            found.insert(VectorTilePatterns.ridge(kind: kind, z: VectorTileStyle.ridgeZ).asset)
            found.insert(VectorTilePatterns.ridge(kind: kind, z: deepest).asset)
        }
        for kind in ["military", "danger_area"] { found.insert(VectorTilePatterns.hatch(kind: kind).asset) }
        return found
    }

    /// `Scripts/carto-points.sh` copies every pattern Carto's style names
    /// into the catalog, less the ones it lists as not drawn. One the map
    /// never draws would ship for nothing, and one missing draws nothing.
    @Test("every pattern in the catalog is one the map draws, and every one it draws is there")
    func catalogMatchesTheTables() throws {
        let catalog = StringCatalogTests.sourceRoot.appending(path: "OpenHikes/Tiles/Vector/CartoIcons.xcassets")
        let shipped = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasPrefix(VectorTilePatterns.assetPrefix) }
            .map { String($0.dropLast(".imageset".count)) }

        #expect(Set(shipped) == named)
        for asset in named {
            #expect(CatalogIcons.shared.pattern(asset: asset, unit: unit) != nil, "\(asset)")
        }
    }

    @Test("a pattern is made at its own size, for the scale the tile is drawn at")
    func patternSizes() throws {
        let trees = try #require(CatalogIcons.shared.pattern(asset: asset("leaftype_unknown"), unit: unit))
        let marks = try #require(CatalogIcons.shared.pattern(asset: asset("wetland"), unit: unit))
        let rows = try #require(CatalogIcons.shared.pattern(asset: asset("allotments"), unit: unit))

        #expect(trees.width == side)
        #expect(trees.height == side)
        #expect(marks.width == side)
        #expect(rows.width == 8 * Int(unit))
        #expect(CatalogIcons.shared.pattern(asset: asset("no_such_pattern"), unit: unit) == nil)
    }

    // MARK: Drawing

    /// A picture whose every pixel says where in it it is: red its column,
    /// green its row. Neither side divides a tile's.
    private let pictureSide = 200

    private func picture() throws -> CGImage {
        let context = try #require(canvas(width: pictureSide, height: pictureSide))
        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: pictureSide * pictureSide * 4)
        for row in 0..<pictureSide {
            for column in 0..<pictureSide {
                let index = (row * context.bytesPerRow) + column * 4
                data[index] = UInt8(column)
                data[index + 1] = UInt8(row)
                data[index + 2] = 0
                data[index + 3] = UInt8.max
            }
        }
        return try #require(context.makeImage())
    }

    private func canvas(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// A canvas the size of a tile's picture, its y running down as the
    /// rasterizer's does.
    private func tileCanvas() throws -> CGContext {
        let context = try #require(canvas(width: side, height: side))
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    /// The red, green and alpha of the pixel `x` across and `y` down.
    private func pixel(_ context: CGContext, x: Int, y: Int) throws -> [Int] {
        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * side)
        let index = y * context.bytesPerRow + x * 4
        return [Int(data[index]), Int(data[index + 1]), Int(data[index + 3])]
    }

    /// The tile at column 7 and row 3 starts 3,584 pixels across the world
    /// and 1,536 down it: 184 and 136 pixels into a copy of a picture 200
    /// pixels on a side.
    @Test("a pattern is laid from the corner of the world, whichever tile draws it")
    func laidFromTheWorldsCorner() throws {
        let target = VectorTileAddress(z: 13, x: 7, y: 3)
        let context = try tileCanvas()

        VectorTilePatterns.lay(try picture(), in: context, target: target)

        for (x, y) in [(0, 0), (10, 5), (100, 300), (side - 1, side - 1)] {
            let column = (target.x * side + x) % pictureSide
            let row = (target.y * side + y) % pictureSide
            #expect(try pixel(context, x: x, y: y) == [column, row, Int(UInt8.max)], "\(x), \(y)")
        }
    }

    @Test("two tiles side by side carry one pattern across their edge")
    func tilesAgreeAtTheirEdge() throws {
        let left = try tileCanvas()
        let right = try tileCanvas()
        let image = try picture()

        VectorTilePatterns.lay(image, in: left, target: VectorTileAddress(z: 13, x: 7, y: 3))
        VectorTilePatterns.lay(image, in: right, target: VectorTileAddress(z: 13, x: 8, y: 3))

        let last = try pixel(left, x: side - 1, y: 40)
        let first = try pixel(right, x: 0, y: 40)
        #expect(first[0] == (last[0] + 1) % pictureSide)
        #expect(first[1] == last[1])
    }

    @Test("a picture laid along a line keeps its middle on the line and stops where the line does")
    func laidAlongALine() throws {
        let context = try tileCanvas()
        let line = [CGPoint(x: 100, y: 300), CGPoint(x: 100 + CGFloat(pictureSide) * 1.5, y: 300)]

        VectorTilePatterns.lay(try picture(), along: line, in: context)

        // The picture's own middle row, 100, lies on the line, and its
        // columns run along it, starting again with each copy.
        #expect(try pixel(context, x: 110, y: 300) == [10, 100, Int(UInt8.max)])
        #expect(try pixel(context, x: 110, y: 250) == [10, 50, Int(UInt8.max)])
        #expect(try pixel(context, x: 100 + pictureSide + 10, y: 300) == [10, 100, Int(UInt8.max)])
        #expect(try pixel(context, x: 100 + pictureSide * 2 - 10, y: 300)[2] == 0, "past the line's end")
        #expect(try pixel(context, x: 90, y: 300)[2] == 0, "before its start")
    }

    // MARK: Teeth

    @Test("a cliff has teeth from zoom 13 and longer ones from 15, and an embankment from 15")
    func whichTeeth() throws {
        #expect(VectorTilePatterns.teeth(kind: "cliff", z: 12) == nil)
        let cliff = try #require(VectorTilePatterns.teeth(kind: "cliff", z: 13))
        let deep = try #require(VectorTilePatterns.teeth(kind: "cliff", z: 15))
        #expect(deep.height > cliff.height)
        #expect(deep.spacing == cliff.spacing)

        #expect(VectorTilePatterns.teeth(kind: "embankment", z: 14) == nil)
        let embankment = try #require(VectorTilePatterns.teeth(kind: "embankment", z: 15))
        #expect(embankment.height < cliff.height)
        #expect(embankment.color != cliff.color)
    }

    /// A cliff is mapped with the drop on its right. The first tooth stands
    /// half a spacing along the line.
    @Test("the teeth stand on the right of the way the line runs", arguments: [false, true])
    func teethOnTheRight(reversed: Bool) throws {
        let teeth = try #require(VectorTilePatterns.teeth(kind: "cliff", z: 15))
        let context = try tileCanvas()
        let ends = [CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 200)]
        let first = Int(teeth.spacing * unit / 2)
        let reach = Int(teeth.height * unit / 2)

        VectorTilePatterns.draw(teeth, along: reversed ? ends.reversed() : ends, in: context, unit: unit)

        let tooth = reversed ? 400 - first : 100 + first
        #expect(try pixel(context, x: 250, y: 200)[2] > 0, "the line itself")
        #expect(try pixel(context, x: tooth, y: reversed ? 200 - reach : 200 + reach)[2] > 0, "the tooth")
        #expect(try pixel(context, x: tooth, y: reversed ? 200 + reach + 2 : 200 - reach - 2)[2] == 0, "the other side")
    }

    @Test("a line too short for a tooth is drawn without one, and a point is nothing")
    func shortLines() throws {
        let teeth = try #require(VectorTilePatterns.teeth(kind: "cliff", z: 13))
        let context = try tileCanvas()

        let stub = [CGPoint(x: 100, y: 200), CGPoint(x: 104, y: 200)]
        VectorTilePatterns.draw(teeth, along: stub, in: context, unit: unit)
        VectorTilePatterns.draw(teeth, along: [CGPoint(x: 300, y: 300)], in: context, unit: unit)

        #expect(try pixel(context, x: 102, y: 200)[2] > 0)
        #expect(try pixel(context, x: 102, y: 204)[2] == 0)
        #expect(try pixel(context, x: 300, y: 300)[2] == 0)
    }
}
