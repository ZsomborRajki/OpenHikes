//
//  VectorTileFixture+Drawing.swift
//  OpenHikesVectorTilesTests
//
//  A tile the fixture wrote, read and drawn as the package reads and draws
//  one, and what a suite asks of the picture. Here rather than beside the
//  writer, which the app's suites share: these reach inside the package.
//

import CoreGraphics
import Foundation
@testable import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport

extension VectorTileFixture {
    /// Every layer and property the rasterizer reads, as it reads them for a
    /// reader of `language`.
    static func decoded(_ layers: [Layer], language: String = "en") throws -> MapboxVectorTile {
        try MapboxVectorTile(
            data: data(layers),
            layerNames: VectorTileRasterizer.layerNames,
            propertyKeys: VectorTileRasterizer.propertyKeys(language: language)
        )
    }

    /// A height as a test reads one, the same in every locale.
    static func height(_ meters: Double) -> String {
        "\(Int(meters.rounded())) m"
    }

    /// `layers`, decoded, drawn as `target` from the archive tile `source`.
    static func image(
        _ layers: [Layer],
        from source: VectorTileAddress,
        drawing target: VectorTileAddress
    ) throws -> CGImage? {
        VectorTileRasterizer.image(
            of: try decoded(layers),
            from: source,
            drawing: target,
            language: "en",
            height: height
        )
    }

    /// Whether any pixel of `image` is `hex`, give or take `tolerance` in
    /// each channel: by default the rounding a color picks up between color
    /// spaces, and more for the ink of a letter, which may cover no pixel
    /// whole.
    static func image(_ image: CGImage, has hex: String, tolerance: Int = 3) -> Bool {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let wanted = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).contains { index in
            (0..<3).allSatisfy { abs(Int(pixels[index + $0]) - wanted[$0]) <= tolerance }
        }
    }

    /// Every color in `image` inside `rect`, as `0xRRGGBB`: `rect` is in the
    /// picture's pixels, its y running down as a tile's does.
    static func colors(of image: CGImage, in rect: CGRect) -> Set<Int> {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var found: Set<Int> = []
        for y in max(Int(rect.minY), 0)..<min(Int(rect.maxY), image.height) {
            for x in max(Int(rect.minX), 0)..<min(Int(rect.maxX), image.width) {
                let index = (y * image.width + x) * 4
                found.insert(Int(pixels[index]) << 16 | Int(pixels[index + 1]) << 8 | Int(pixels[index + 2]))
            }
        }
        return found
    }

    /// `hex` as ``colors(of:in:)`` gives a color.
    static func color(_ hex: String) -> Int {
        Int(hex.dropFirst(), radix: 16) ?? 0
    }

    /// A rectangle of the tile's grid, as the picture's pixels: the part of
    /// a ``VectorTileRasterizer/pixelSize`` picture it covers when the tile
    /// is drawn as itself, drawn in by `inset` pixels to stay off its edge.
    static func pixels(x: ClosedRange<Int>, y: ClosedRange<Int>, inset: CGFloat = 4) -> CGRect {
        let scale = CGFloat(VectorTileRasterizer.pixelSize) / CGFloat(grid)
        return CGRect(
            x: CGFloat(x.lowerBound) * scale,
            y: CGFloat(y.lowerBound) * scale,
            width: CGFloat(x.upperBound - x.lowerBound) * scale,
            height: CGFloat(y.upperBound - y.lowerBound) * scale
        )
        .insetBy(dx: inset, dy: inset)
    }
}
