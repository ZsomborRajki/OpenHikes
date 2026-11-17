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

    @Test("a road is drawn over the ground in its color")
    func roadOverGround() throws {
        let streetZoom = VectorTileAddress(z: 16, x: 35_200, y: 22_800)
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

    @Test("summits are marked from zoom 12, and not before")
    func peaksFromZoomTwelve() throws {
        let layers = [
            land,
            .init(name: "pois", features: [
                .init(
                    type: .point,
                    properties: ["kind": .string("peak")],
                    geometry: VectorTileFixture.points([(grid / 2, grid / 2)])
                ),
            ]),
        ]

        let close = try draw(layers, at: VectorTileAddress(z: VectorTileStyle.peakZ, x: 2200, y: 1425))
        let wide = try draw(layers, at: VectorTileAddress(z: VectorTileStyle.peakZ - 1, x: 1100, y: 712))

        #expect(pixel(close, x: middle, y: middle, is: "#8A5A3B"))
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
        let expected = components(of: hex)
        let actual = components(of: image, x: x, y: y)
        let tolerance = 3
        return zip(expected, actual).allSatisfy { abs($0 - $1) <= tolerance }
    }

    private func components(of hex: String) -> [Int] {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }

    private func components(of image: CGImage, x: Int, y: Int) -> [Int] {
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
        let index = (y * width + x) * 4
        return [Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])]
    }
}
