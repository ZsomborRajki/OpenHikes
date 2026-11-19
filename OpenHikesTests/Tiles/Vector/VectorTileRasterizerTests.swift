//
//  VectorTileRasterizerTests.swift
//  OpenHikesTests
//
//  Pictures drawn from tiles written by `VectorTileFixture`, read back pixel
//  by pixel: what is drawn where, in what color, and how a tile deeper than
//  the archive is cut from the one that holds it.
//

import CoreGraphics
import Foundation
import ImageIO
@testable import OpenHikes
import Testing

@Suite("Vector tile rasterizer")
struct VectorTileRasterizerTests {
    private let tile = VectorTileAddress(z: 14, x: 8800, y: 5700)
    private let grid = VectorTileFixture.grid
    private let middle = VectorTileRasterizer.pixelSize / 2
    /// A pixel well inside the left half of a picture, and one in the right.
    private let left = VectorTileRasterizer.pixelSize / 5
    private let right = VectorTileRasterizer.pixelSize * 4 / 5

    private var land: VectorTileFixture.Layer {
        .init(name: "earth", features: [
            .init(type: .polygon, properties: ["kind": .string("earth")], geometry: whole),
        ])
    }

    private var whole: [UInt32] { VectorTileFixture.rectangle(x: 0...grid, y: 0...grid) }
    private var leftHalf: [UInt32] { VectorTileFixture.rectangle(x: 0...(grid / 2), y: 0...grid) }
    private var rightHalf: [UInt32] { VectorTileFixture.rectangle(x: (grid / 2)...grid, y: 0...grid) }
    private var topHalf: [UInt32] { VectorTileFixture.rectangle(x: 0...grid, y: 0...(grid / 2)) }

    @Test("with nothing on it a tile is open water")
    func emptyTileIsOcean() throws {
        let image = try draw([], at: tile)

        #expect(image.width == VectorTileRasterizer.pixelSize)
        #expect(image.height == VectorTileRasterizer.pixelSize)
        #expect(pixel(image, x: middle, y: middle, is: "#AAD3DF"))
    }

    @Test("land is drawn over the sea, and a lake over the land")
    func landThenWater() throws {
        let layers = [
            land,
            .init(name: "water", features: [
                .init(type: .polygon, properties: ["kind": .string("water")], geometry: leftHalf),
            ]),
        ]

        let image = try draw(layers, at: tile)

        #expect(pixel(image, x: left, y: middle, is: "#AAD3DF"))
        #expect(pixel(image, x: right, y: middle, is: "#F2EFE9"))
    }

    @Test("landuse is filled by its kind, and a kind with no fill is left as land")
    func landuseByKind() throws {
        let layers = [
            land,
            .init(name: "landuse", features: [
                .init(type: .polygon, properties: ["kind": .string("forest")], geometry: rightHalf),
                .init(type: .polygon, properties: ["kind": .string("no_such_kind")], geometry: leftHalf),
            ]),
        ]

        let image = try draw(layers, at: tile)

        #expect(pixel(image, x: right, y: middle, is: "#ADD19E"))
        #expect(pixel(image, x: left, y: middle, is: "#F2EFE9"))
    }

    /// Every area in the archive has the same `sort_rank`, and a city's
    /// residential area comes after the gardens inside it as often as before:
    /// drawn in the tile's order, it covered them.
    @Test("a smaller area is drawn over the larger one it lies in, in either order", arguments: [false, true])
    func smallerAreaOverLarger(parkFirst: Bool) throws {
        let residential = VectorTileFixture.Feature(
            type: .polygon,
            properties: ["kind": .string("residential"), "sort_rank": .int(189)],
            geometry: whole
        )
        let park = VectorTileFixture.Feature(
            type: .polygon,
            properties: ["kind": .string("garden"), "sort_rank": .int(189)],
            geometry: leftHalf
        )
        let listed = parkFirst ? [park, residential] : [residential, park]

        let image = try draw([land, .init(name: "landuse", features: listed)], at: tile)

        #expect(pixel(image, x: left, y: middle, is: "#CDEBB0"), "the garden")
        #expect(pixel(image, x: right, y: middle, is: "#E0DFDF"), "the residential area around it")
    }

    /// The archive stops at zoom 15, and the map goes deeper. A deeper tile is
    /// the part of the archive tile it lies in, so a lake on the left half of
    /// the archive tile fills the left child and none of the right.
    @Test("a deeper tile draws the part of the archive tile it covers")
    func deeperTileIsCutFromItsAncestor() throws {
        let layers = [
            land,
            .init(name: "water", features: [
                .init(type: .polygon, properties: ["kind": .string("water")], geometry: leftHalf),
            ]),
        ]
        let leftChild = VectorTileAddress(z: tile.z + 1, x: tile.x * 2, y: tile.y * 2)
        let rightChild = VectorTileAddress(z: tile.z + 1, x: tile.x * 2 + 1, y: tile.y * 2 + 1)
        // Three zooms down, the last column of the eight across.
        let rightmost = VectorTileAddress(z: tile.z + 3, x: tile.x * 8 + 7, y: tile.y * 8)

        let leftImage = try draw(layers, from: tile, at: leftChild)
        let rightImage = try draw(layers, from: tile, at: rightChild)
        let rightmostImage = try draw(layers, from: tile, at: rightmost)

        #expect(pixel(leftImage, x: left, y: middle, is: "#AAD3DF"))
        #expect(pixel(leftImage, x: right, y: middle, is: "#AAD3DF"), "the whole left child is lake")
        #expect(pixel(rightImage, x: left, y: middle, is: "#F2EFE9"), "and the whole right child is land")
        #expect(pixel(rightmostImage, x: middle, y: middle, is: "#F2EFE9"))
    }

    /// The same cut down the tile: a lake over the top half of the archive
    /// tile fills its top children and none of its bottom ones.
    @Test("a deeper tile is cut from its ancestor's rows as from its columns")
    func deeperTileIsCutByRow() throws {
        let layers = [
            land,
            .init(name: "water", features: [
                .init(type: .polygon, properties: ["kind": .string("water")], geometry: topHalf),
            ]),
        ]
        let topChild = VectorTileAddress(z: tile.z + 1, x: tile.x * 2 + 1, y: tile.y * 2)
        let bottomChild = VectorTileAddress(z: tile.z + 1, x: tile.x * 2, y: tile.y * 2 + 1)

        #expect(pixel(try draw(layers, from: tile, at: topChild), x: middle, y: right, is: "#AAD3DF"))
        #expect(pixel(try draw(layers, from: tile, at: bottomChild), x: middle, y: left, is: "#F2EFE9"))
    }

    /// The spec has every line begin with a move, and a tile off the network
    /// may still not: the stray stretch is left out rather than trusted.
    @Test("a line that starts without a move is read without it")
    func lineWithoutAMoveIsSkipped() throws {
        // A line to (10, 10) with no move before it, then a line of its own.
        let stray: [UInt32] = [2 | 1 << 3, 20, 20] + VectorTileFixture.line([(0, 0), (grid, 0)])
        let decoded = try VectorTileFixture.decoded([
            .init(name: "roads", features: [.init(type: .line, properties: [:], geometry: stray)]),
        ])
        let roads = try #require(decoded.layers["roads"])
        let geometry = VectorTileGeometry(extent: roads.extent, source: tile, target: tile)

        let lines = try #require(roads.features.first.map(geometry.lines(of:)))

        #expect(lines.count == 1)
        #expect(lines.first?.count == 2)
    }

    @Test("a road is drawn over the ground in its color")
    func roadOverGround() throws {
        let layers = [
            land,
            .init(name: "roads", features: [
                .init(
                    type: .line,
                    properties: ["kind": .string("minor_road"), "kind_detail": .string("residential")],
                    geometry: VectorTileFixture.line([(-grid / 4, grid / 2), (grid + grid / 4, grid / 2)])
                ),
            ]),
        ]

        let image = try draw(layers, at: streetZoom)

        #expect(pixel(image, x: middle, y: middle, is: "#FFFFFF"))
        #expect(pixel(image, x: middle, y: left, is: "#F2EFE9"))
    }

    /// The archive has no kind for a living street: it files one as `other`,
    /// with the highway as its detail, the tags of Hallstatt's Seestraße.
    @Test("a living street is drawn as the street it is")
    func livingStreetIsDrawn() throws {
        let livingStreet = street(kind: "other", detail: "living_street", across: true)

        let image = try draw([land, roads([livingStreet])], at: streetZoom)

        #expect(pixel(image, x: middle, y: middle, is: "#EDEDED"))
    }

    /// Every road in the archive has the same `sort_rank`, so the order is
    /// the road's own: the primary road's surface runs through the junction
    /// whichever of the two the tile lists first.
    @Test("the more important road is drawn over the junction, in either order", arguments: [false, true])
    func junctionTakesTheMoreImportantRoad(primaryFirst: Bool) throws {
        let primary = street(kind: "major_road", detail: "primary", across: true)
        let residential = street(kind: "minor_road", detail: "residential", across: false)
        let listed = primaryFirst ? [primary, residential] : [residential, primary]

        let image = try draw([land, roads(listed)], at: streetZoom)

        #expect(pixel(image, x: middle, y: middle, is: "#FCD6A4"))
    }

    /// The casing is drawn from zoom 12, a service road and a pedestrian
    /// street from 13. A casing with no road inside it would be a gray line
    /// of its own, two pixels wide, where the road is not drawn at all.
    @Test(
        "a road not yet drawn at its zoom has no casing either",
        arguments: [("minor_road", "service", "#BBBBBB"), ("path", "pedestrian", "#999999")]
    )
    func noCasingBeforeTheRoad(kind: String, detail: String, casing: String) throws {
        let layers = [land, roads([street(kind: kind, detail: detail, across: true)])]

        let wide = try draw(layers, at: VectorTileAddress(z: 12, x: 2200, y: 1425))
        let near = try draw(layers, at: VectorTileAddress(z: 13, x: 4400, y: 2850))

        #expect(pixel(wide, x: middle, y: middle, is: "#F2EFE9"))
        #expect(!row(wide, y: middle, has: casing))
        #expect(!pixel(near, x: middle, y: middle, is: "#F2EFE9"), "where the road is drawn")
    }

    /// Hallstatt's Kirchenstiege is tagged `access=no`, its wall collapsing.
    /// Carto draws closed steps gray rather than salmon, and a closed path
    /// not at all before zoom 15. The rows are read whole, so a gap in the
    /// steps' dashes cannot stand where the test looks.
    @Test("closed steps are drawn in Carto's gray, and not before zoom 15")
    func closedStepsAreGray() throws {
        let closed = [land, roads([street(kind: "path", detail: "steps", across: true, access: "no")])]
        let open = [land, roads([street(kind: "path", detail: "steps", across: true, access: "yes")])]

        let closedNear = try draw(closed, at: streetZoom)
        let openNear = try draw(open, at: streetZoom)
        let closedWide = try draw(closed, at: tile)
        let openWide = try draw(open, at: tile)

        #expect(row(closedNear, y: middle, has: "#BBBBBB"))
        #expect(!row(closedNear, y: middle, has: "#FA8072"))
        #expect(row(openNear, y: middle, has: "#FA8072"))
        #expect(!row(openNear, y: middle, has: "#BBBBBB"))
        #expect(!row(closedWide, y: middle, has: "#BBBBBB"), "a closed path waits for zoom 15")
        #expect(!row(closedWide, y: middle, has: "#FA8072"), "and is never drawn as an open one")
        #expect(row(openWide, y: middle, has: "#FA8072"), "where an open one is drawn")
    }

    /// The vector extras bring fences, walls and hedges, which Carto draws
    /// from zoom 16, a hedge in the woods' green.
    @Test("a hedge from the extras is drawn in Carto's green, and not before zoom 16")
    func hedgeIsDrawn() throws {
        let hedge = VectorTileFixture.Feature(
            type: .line,
            properties: ["kind": .string("hedge")],
            geometry: VectorTileFixture.line([(-grid / 4, grid / 2), (grid + grid / 4, grid / 2)])
        )
        let layers = [land, .init(name: "barriers", features: [hedge])]

        let close = try draw(layers, at: streetZoom)
        let wide = try draw(layers, at: VectorTileAddress(z: 15, x: 17_600, y: 11_400))

        #expect(pixel(close, x: middle, y: middle, is: "#ADD19E"))
        #expect(pixel(wide, x: middle, y: middle, is: "#F2EFE9"))
    }

    @Test("the PNG handed to the cache is the size it was drawn at")
    func pngKeepsItsSize() throws {
        let decoded = try VectorTileFixture.decoded([land])
        let png = try #require(VectorTileRasterizer.png(
            of: decoded,
            from: tile,
            drawing: tile,
            language: "en",
            height: VectorTileFixture.height
        ))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(image.width == VectorTileRasterizer.pixelSize)
        #expect(pixel(image, x: middle, y: middle, is: "#F2EFE9"))
    }

    // MARK: Helpers

    /// Deep enough that every road is drawn wide.
    private let streetZoom = VectorTileAddress(z: 16, x: 35_200, y: 22_800)

    private func roads(_ features: [VectorTileFixture.Feature]) -> VectorTileFixture.Layer {
        .init(name: "roads", features: features)
    }

    /// A road through the middle of the tile, across it or down it, ranked
    /// as the archive ranks every road.
    private func street(
        kind: String,
        detail: String,
        across: Bool,
        access: String? = nil
    ) -> VectorTileFixture.Feature {
        let ends = [-grid / 4, grid + grid / 4].map { across ? ($0, grid / 2) : (grid / 2, $0) }
        var properties: [String: VectorTileFixture.Value] = [
            "kind": .string(kind), "kind_detail": .string(detail), "sort_rank": .int(400),
        ]
        if let access { properties["access"] = .string(access) }
        return .init(type: .line, properties: properties, geometry: VectorTileFixture.line(ends))
    }

    private func draw(_ layers: [VectorTileFixture.Layer], at target: VectorTileAddress) throws -> CGImage {
        try draw(layers, from: target, at: target)
    }

    private func draw(
        _ layers: [VectorTileFixture.Layer],
        from source: VectorTileAddress,
        at target: VectorTileAddress
    ) throws -> CGImage {
        let decoded = try VectorTileFixture.decoded(layers)
        return try #require(VectorTileRasterizer.image(
            of: decoded,
            from: source,
            drawing: target,
            language: "en",
            height: VectorTileFixture.height
        ))
    }

    /// Whether the pixel at `x`, `y` (from the top left) is `hex`, give or take
    /// the rounding a color picks up between color spaces.
    private func pixel(_ image: CGImage, x: Int, y: Int, is hex: String) -> Bool {
        matches(components(of: image, x: x, y: y), hex)
    }

    /// Whether any pixel along row `y` is `hex`, as ``pixel(_:x:y:is:)`` judges one.
    private func row(_ image: CGImage, y: Int, has hex: String) -> Bool {
        let pixels = rgba(of: image)
        return (0..<image.width).contains { x in
            let index = (y * image.width + x) * 4
            return matches([Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])], hex)
        }
    }

    private func matches(_ actual: [Int], _ hex: String) -> Bool {
        let tolerance = 3
        return zip(components(of: hex), actual).allSatisfy { abs($0 - $1) <= tolerance }
    }

    private func components(of hex: String) -> [Int] {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }

    private func components(of image: CGImage, x: Int, y: Int) -> [Int] {
        let pixels = rgba(of: image)
        let index = (y * image.width + x) * 4
        return [Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])]
    }

    /// `image`'s pixels in sRGB, four bytes each, row by row from the top.
    private func rgba(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}

// MARK: Piers

extension VectorTileRasterizerTests {
    /// Hallstatt Markt's ferry landing, tile 15/17626/11449, has both: an
    /// area of `landuse` kind `pier`, and a line in `roads` filed as a path
    /// with the detail `pier`, each standing in the lake. Carto draws them in
    /// the land's color over the water from zoom 12, the line solid; the
    /// area had no fill, and the line was drawn as a dashed footpath.
    @Test("a pier is drawn over the water it stands in, as an area and as a line")
    func pierOverWater() throws {
        let lake = VectorTileFixture.Layer(name: "water", features: [
            .init(type: .polygon, properties: ["kind": .string("lake")], geometry: whole),
        ])
        let deck = VectorTileFixture.Layer(name: "landuse", features: [
            .init(type: .polygon, properties: ["kind": .string("pier")], geometry: leftHalf),
        ])
        let layers = [land, lake, deck, roads([street(kind: "path", detail: "pier", across: true)])]

        let close = try draw(layers, at: streetZoom)
        let wide = try draw(layers, at: VectorTileAddress(z: 11, x: 1100, y: 712))

        #expect(pixel(close, x: left, y: left, is: "#F2EFE9"), "the deck")
        #expect(pixel(close, x: right, y: left, is: "#AAD3DF"), "the lake beside it")
        #expect(pixel(close, x: right, y: middle, is: "#F2EFE9"), "the walkway out over the lake")
        #expect(!row(close, y: middle, has: "#FA8072"), "which is no footpath")
        #expect(pixel(wide, x: left, y: left, is: "#AAD3DF"), "and neither is drawn before zoom 12")
    }
}

// MARK: The extras' ground and lines

extension VectorTileRasterizerTests {
    private func area(_ kind: String, in layer: String, _ geometry: [UInt32]) -> VectorTileFixture.Layer {
        .init(name: layer, features: [.init(type: .polygon, properties: ["kind": .string(kind)], geometry: geometry)])
    }

    /// Triglav's rock and ice were filled in a city park's green: the basemap
    /// files most national parks under the kind it files a park under.
    @Test("a park is filled from the extras' own layer, from zoom 10, and the basemap's park not at all")
    func parksAreTheExtras() throws {
        let layers = [land, area("park", in: "landuse", rightHalf), area("park", in: "parks", leftHalf)]

        let image = try draw(layers, at: tile)
        let wide = try draw(layers, at: VectorTileAddress(z: 9, x: 275, y: 178))

        #expect(pixel(image, x: left, y: middle, is: "#C8FACC"), "the extras' park")
        #expect(pixel(image, x: right, y: middle, is: "#F2EFE9"), "the basemap's is left as the ground it lies on")
        #expect(pixel(wide, x: left, y: middle, is: "#F2EFE9"), "and no park is filled before zoom 10")
    }

    @Test("the extras' area is drawn over the basemap's of the same ground")
    func extrasGroundOverTheBasemaps() throws {
        let ground = VectorTileFixture.Layer(name: "landuse", features: [
            .init(type: .polygon, properties: ["kind": .string("farmland")], geometry: whole),
            .init(type: .polygon, properties: ["kind": .string("orchard")], geometry: whole),
        ])

        let image = try draw([land, ground], at: tile)

        #expect(pixel(image, x: middle, y: middle, is: "#AEDFA3"), "the orchard the basemap files as farmland")
    }

    @Test("scree and heath are filled in Carto's colors")
    func screeAndHeath() throws {
        let ground = VectorTileFixture.Layer(name: "landuse", features: [
            .init(type: .polygon, properties: ["kind": .string("scree")], geometry: leftHalf),
            .init(type: .polygon, properties: ["kind": .string("heath")], geometry: rightHalf),
        ])

        let image = try draw([land, ground], at: tile)

        #expect(pixel(image, x: left, y: middle, is: "#EEE5DC"))
        #expect(pixel(image, x: right, y: middle, is: "#D6D99F"))
    }

    /// At zoom 14 Carto's band is six pixels wide, inside the border.
    @Test("a protected area's border is a band inside its edge, and the ground within is left as it was")
    func protectedBorder() throws {
        let layers = [land, area("protected_area", in: "protected_areas", leftHalf)]
        let band = 8

        let image = try draw(layers, at: tile)
        let wide = try draw(layers, at: VectorTileAddress(z: 7, x: 68, y: 44))

        #expect(!pixel(image, x: middle - band, y: middle, is: "#F2EFE9"), "the band, just inside the border")
        #expect(pixel(image, x: left, y: middle, is: "#F2EFE9"), "the ground further in")
        #expect(pixel(image, x: middle + band, y: middle, is: "#F2EFE9"), "and nothing outside it")
        #expect(pixel(wide, x: middle - 1, y: middle, is: "#F2EFE9"), "no border before zoom 8")
    }

    @Test("a building is drawn, and a part of one is not")
    func buildingPartsAreLeftOut() throws {
        let buildings = VectorTileFixture.Layer(name: "buildings", features: [
            .init(type: .polygon, properties: ["kind": .string("building")], geometry: leftHalf),
            .init(type: .polygon, properties: ["kind": .string("building_part")], geometry: rightHalf),
        ])

        let image = try draw([land, buildings], at: tile)

        #expect(pixel(image, x: left, y: middle, is: "#D9D0C9"))
        #expect(pixel(image, x: right, y: middle, is: "#F2EFE9"))
    }

    @Test("a dam mapped as an area is filled from zoom 13")
    func damArea() throws {
        let layers = [land, area("dam", in: "landuse", leftHalf)]

        let image = try draw(layers, at: tile)
        let wide = try draw(layers, at: VectorTileAddress(z: 12, x: 2200, y: 1425))

        #expect(pixel(image, x: left, y: middle, is: "#ADADAD"))
        #expect(pixel(wide, x: left, y: middle, is: "#F2EFE9"))
    }

    /// The archive files a station's outline as a railway of the detail
    /// `station`, and Penn Station was ringed with dashed track.
    @Test("a gondola is drawn as a lift, a runway as a runway, and a station's outline not as track")
    func liftsRunwaysAndStations() throws {
        let lift = try draw([land, roads([street(kind: "aerialway", detail: "gondola", across: true)])], at: tile)
        let runway = try draw([land, roads([street(kind: "aeroway", detail: "runway", across: true)])], at: tile)
        let station = try draw([land, roads([street(kind: "rail", detail: "station", across: true)])], at: tile)
        let track = try draw([land, roads([street(kind: "rail", detail: "rail", across: true)])], at: tile)

        #expect(row(lift, y: middle, has: "#808080"))
        #expect(pixel(runway, x: left, y: middle, is: "#BBBBCC"))
        #expect(pixel(station, x: left, y: middle, is: "#F2EFE9"))
        #expect(!pixel(track, x: left, y: middle, is: "#F2EFE9"))
    }

    @Test("a power line, a weir and a ridge from the extras are drawn, each from its zoom")
    func extrasLines() throws {
        let across = VectorTileFixture.line([(-grid / 4, grid / 2), (grid + grid / 4, grid / 2)])
        let layers = [
            land,
            VectorTileFixture.Layer(name: "power", features: [
                .init(type: .line, properties: ["kind": .string("line")], geometry: across),
            ]),
        ]
        let weir = VectorTileFixture.Layer(name: "dams", features: [
            .init(type: .line, properties: ["kind": .string("weir")], geometry: across),
        ])
        let arete = VectorTileFixture.Layer(name: "ridges", features: [
            .init(type: .line, properties: ["kind": .string("arete")], geometry: across),
        ])

        let power = try draw(layers, at: streetZoom)
        let early = try draw(layers, at: VectorTileAddress(z: 13, x: 4400, y: 2850))

        #expect(!pixel(power, x: left, y: middle, is: "#F2EFE9"))
        #expect(pixel(early, x: left, y: middle, is: "#F2EFE9"), "no power line before zoom 14")
        #expect(row(try draw([land, weir], at: tile), y: middle, has: "#AAAAAA"))
        #expect(!pixel(try draw([land, arete], at: streetZoom), x: left, y: middle, is: "#F2EFE9"))
    }
}
