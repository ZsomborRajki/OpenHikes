//
//  VectorTilePaletteTests.swift
//  OpenHikesTests
//
//  A palette says what each of the style's colors is on the picture: Carto's
//  own changes none, and another's translates one by what it is put down as,
//  by its tables first and its rule after them, and keeps a see-through color
//  as see-through as it was. A pattern's picture is translated a color at a
//  time and kept.
//

import CoreGraphics
@testable import OpenHikes
import RealModule
import Synchronization
import Testing

@Suite("Vector tile palette")
struct VectorTilePaletteTests {
    /// White is a surface's gray and anything else's near-black, one blue has
    /// a counterpart whatever it is, and the rule turns any other color into
    /// its complement.
    private let palette = VectorTilePalette(
        name: "test",
        isDark: true,
        shared: [("#FFFFFF", "#101010"), ("#112233", "#445566"), ("not a color", "#000000")],
        roles: [.surface: [("#FFFFFF", "#404040")], .pattern: [("#00FF00", "#008800")]],
        otherwise: { rgb, _ in rgb ^ 0xFFFFFF }
    )

    private func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        VectorTileStyle.color(hex, alpha: alpha)
    }

    private func rgb(_ color: CGColor) -> UInt32? {
        VectorTilePalette.components(of: color)?.rgb
    }

    @Test("Carto's palette hands every color back as it is", arguments: VectorTilePalette.Role.allCases)
    func cartoChangesNothing(role: VectorTilePalette.Role) {
        let salmon = color("#FA8072", alpha: 0.4)
        #expect(VectorTilePalette.carto.color(salmon, as: role) === salmon)
        #expect(VectorTilePalette.carto.isCarto)
        #expect(!VectorTilePalette.carto.isDark)
        #expect(VectorTilePalette.carto.names(salmon, as: role))
    }

    @Test("a role's own color for one of Carto's wins, and every other role takes the shared one")
    func rolesComeFirst() {
        #expect(rgb(palette.color(color("#FFFFFF"), as: .surface)) == 0x404040)
        for role in VectorTilePalette.Role.allCases where role != .surface {
            #expect(rgb(palette.color(color("#FFFFFF"), as: role)) == 0x101010, "\(role)")
        }
        #expect(rgb(palette.color(color("#112233"), as: .surface)) == 0x445566)
    }

    @Test("a color no table names is the rule's, and is not named")
    func ruleComesLast() {
        let orange = color("#FF8000")
        #expect(rgb(palette.color(orange, as: .line)) == 0x007FFF)
        #expect(!palette.names(orange, as: .line))
        #expect(palette.names(color("#112233"), as: .line))
        #expect(palette.names(color("#FFFFFF"), as: .surface))
        #expect(!palette.isCarto)
    }

    @Test("an entry that is not a color is left out, rather than naming black")
    func malformedEntriesAreLeftOut() {
        #expect(VectorTilePalette.rgb(hex: "not a color") == nil)
        #expect(VectorTilePalette.rgb(hex: "#12345") == nil)
        #expect(VectorTilePalette.rgb(hex: "112233") == nil)
        #expect(VectorTilePalette.rgb(hex: "#112233") == 0x112233)
        // Black is not named by the malformed entry's right-hand side.
        #expect(rgb(palette.color(color("#000000"), as: .text)) == 0xFFFFFF)
    }

    @Test("a see-through color is translated and stays as see-through", arguments: [0.4, 0.9])
    func alphaIsKept(alpha: Double) throws {
        let translated = palette.color(color("#FFFFFF", alpha: CGFloat(alpha)), as: .halo)
        let components = try #require(VectorTilePalette.components(of: translated))
        #expect(components.rgb == 0x101010)
        #expect(components.alpha.isApproximatelyEqual(to: CGFloat(alpha), absoluteTolerance: 0.001))
    }

    @Test("a gray is read as the color it is, and a color in neither space is left alone")
    func otherColorSpaces() throws {
        let white = CGColor(gray: 1, alpha: 1)
        #expect(rgb(palette.color(white, as: .line)) == 0x101010)
        let space = try #require(CGColorSpace(name: CGColorSpace.genericCMYK))
        let ink = try #require(CGColor(colorSpace: space, components: [0, 0, 0, 1, 1]))
        #expect(palette.color(ink, as: .line) === ink)
    }

    @Test("the same color asked for twice is the same object, made once")
    func colorsAreKept() {
        let first = palette.color(color("#112233"), as: .fill)
        #expect(palette.color(color("#112233"), as: .fill) === first)
    }

    @Test("palettes are told apart by name")
    func identity() {
        #expect(VectorTilePalette.carto == .carto)
        #expect(VectorTilePalette.dark != .carto)
        #expect(palette != .dark)
        #expect(Set([VectorTilePalette.carto, .dark, .dark]).count == 2)
    }

    // MARK: Patterns

    @Test("a pattern is drawn in the palette's colors, as see-through at each pixel as it was, and kept")
    func patternsAreTranslated() throws {
        // Half the picture solid green, a quarter the shared blue half
        // see-through, and the rest clear.
        let icons = PatternStub(picture: PatternStub.picture(rows: [
            (0x00FF00, 255), (0x00FF00, 255), (0x112233, 128), (0x000000, 0),
        ]))
        let drawn = try #require(palette.pattern("carto-pattern-test", unit: 2, from: icons))
        let pixels = PatternStub.pixels(of: drawn)

        #expect(pixels[0] == PatternStub.Pixel(rgb: 0x008800, alpha: 255), "the pattern's own table first")
        #expect(pixels[2].alpha == 128)
        // A color read back off see-through pixels is a rounding off the one
        // it was drawn in, and still takes that one's counterpart.
        #expect(PatternStub.distance(pixels[2].rgb, 0x445566) <= 2)
        #expect(pixels[3].alpha == 0)

        _ = palette.pattern("carto-pattern-test", unit: 2, from: icons)
        #expect(icons.asked == 1, "the translated picture is kept")
        _ = palette.pattern("carto-pattern-test", unit: 1, from: icons)
        #expect(icons.asked == 2, "each size is its own picture")
    }

    @Test("Carto's palette draws the pattern as the catalog has it, and no palette draws one that is missing")
    func patternsPassThrough() {
        let icons = PatternStub(picture: PatternStub.picture(rows: [(0x00FF00, 255)]))
        #expect(VectorTilePalette.carto.pattern("carto-pattern-test", unit: 2, from: icons) === icons.picture)
        let none = PatternStub(picture: nil)
        #expect(palette.pattern("carto-pattern-none", unit: 2, from: none) == nil)
        #expect(VectorTilePalette.carto.pattern("carto-pattern-none", unit: 2, from: none) == nil)
    }
}

/// A catalog of one pattern, which counts how often it is asked for.
nonisolated private final class PatternStub: VectorTileIconDrawing, Sendable {
    struct Pixel: Equatable {
        let rgb: UInt32
        let alpha: UInt8
    }

    let picture: CGImage?
    private let count = Mutex(0)

    var asked: Int { count.withLock { $0 } }

    init(picture: CGImage?) {
        self.picture = picture
    }

    func image(asset: String, fill: CGColor?, size: CGSize) -> CGImage? { nil }

    func pattern(asset: String, unit: CGFloat) -> CGImage? {
        count.withLock { $0 += 1 }
        return picture
    }

    private static let side = 8

    /// A picture of as many bands as `rows`, top first, each one color at one
    /// opacity.
    static func picture(rows: [(rgb: UInt32, alpha: UInt8)]) -> CGImage? {
        let height = rows.count * side
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        for (index, row) in rows.enumerated() {
            let color = VectorTilePalette.color(rgb: row.rgb).copy(alpha: CGFloat(row.alpha) / 255)
            context.setFillColor(color ?? VectorTilePalette.color(rgb: row.rgb))
            // Core Graphics' rows run up.
            context.fill(CGRect(x: 0, y: height - (index + 1) * side, width: side, height: side))
        }
        return context.makeImage()
    }

    /// The middle pixel of each band of `image`, top first, its color with
    /// the opacity divided back out.
    static func pixels(of image: CGImage) -> [Pixel] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
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
        return stride(from: side / 2, to: image.height, by: side).map { row in
            let offset = (row * image.width + image.width / 2) * 4
            let alpha = Int(bytes[offset + 3])
            let channel = { (index: Int) in
                UInt32(alpha == 0 ? 0 : min(Int(bytes[offset + index]) * 255 / alpha, 255))
            }
            return Pixel(rgb: channel(0) << 16 | channel(1) << 8 | channel(2), alpha: bytes[offset + 3])
        }
    }

    static func distance(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        [16, 8, 0].map { abs(Int((lhs >> $0) & 0xFF) - Int((rhs >> $0) & 0xFF)) }.max() ?? 0
    }
}
