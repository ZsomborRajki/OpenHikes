//
//  VectorTilePointStyleTests.swift
//  OpenHikesTests
//
//  The table of points the app ships, read from OpenStreetMap Carto by
//  `Scripts/carto-points.sh`: that it is there, that every icon it names is
//  in the asset catalog, and that it says what Carto's style says for the
//  points a hiker looks for.
//

import CoreGraphics
@testable import OpenHikes
import Testing

@Suite("Vector tile point style")
struct VectorTilePointStyleTests {
    private let style = VectorTilePointStyle.bundled

    @Test("the table is Carto's, and every icon it names is in the app and can be drawn")
    func everyIconIsShipped() {
        #expect(style.source.hasPrefix("openstreetmap-carto v"))
        #expect(style.kindCount > 500)
        let missing = style.assets.filter { asset in
            CatalogIcons.shared.image(asset: asset, fill: VectorTileStyle.color("#000000"), size: iconSize) == nil
        }
        #expect(missing.isEmpty, "not in CartoIcons.xcassets: \(missing.sorted())")
    }

    @Test("an icon is drawn in the color asked for")
    func iconTakesItsFill() throws {
        let image = try #require(CatalogIcons.shared.image(
            asset: "carto-amenity-parking",
            fill: VectorTileStyle.color("#0092DA"),
            size: iconSize
        ))

        let inked = try #require(opaquePixels(of: image).first)
        #expect(abs(inked.red - 0x00) <= 3 && abs(inked.green - 0x92) <= 3 && abs(inked.blue - 0xDA) <= 3)
        #expect(CatalogIcons.shared.image(asset: "carto-no-such-icon", fill: nil, size: iconSize) == nil)
    }

    @Test("a car park is marked from zoom 17 in Carto's blue, and named from 18")
    func parking() throws {
        #expect(style.look(kind: "parking", detail: nil, named: true, z: 16) == nil)

        let marked = try #require(style.look(kind: "parking", detail: nil, named: true, z: 17))
        let named = try #require(style.look(kind: "parking", detail: nil, named: true, z: 18))

        #expect(marked.icons.first?.asset == "carto-amenity-parking")
        #expect(marked.icons.first?.fill == VectorTileStyle.color("#0092DA"))
        #expect(marked.text == nil)
        #expect(named.text != nil)
    }

    @Test("a restaurant is a dot at zoom 17 and its icon from 18")
    func restaurant() throws {
        let dot = try #require(style.look(kind: "restaurant", detail: nil, named: true, z: 17)?.icons.first)
        let icon = try #require(style.look(kind: "restaurant", detail: nil, named: true, z: 18)?.icons.first)

        #expect(dot.asset == nil)
        #expect(dot.size == CGSize(width: 4, height: 4))
        #expect(icon.asset == "carto-amenity-restaurant")
    }

    @Test("a place of worship takes its religion's icon, and the plain one for a religion Carto draws none for")
    func religion() {
        let icon = { (religion: String?) in
            style.look(kind: "place_of_worship", detail: religion, named: true, z: 17)?.icons.first?.asset
        }

        #expect(icon("christian") == "carto-religion-christian")
        #expect(icon("jewish") == "carto-religion-jewish")
        #expect(icon("pastafarian") == "carto-amenity-place_of_worship")
        #expect(icon(nil) == "carto-amenity-place_of_worship")
    }

    @Test("a summit is marked from zoom 11 and named with its height from 13")
    func summit() throws {
        let marked = try #require(style.look(kind: "peak", detail: nil, named: true, z: 11))
        let named = try #require(style.look(kind: "peak", detail: nil, named: true, z: 13))

        #expect(marked.icons.first?.asset == "carto-natural-peak")
        #expect(marked.text == nil)
        #expect(named.text != nil)
        #expect(named.showsElevation)
    }

    @Test("benches and wayside crosses claim room last; huts and fuel do not")
    func lowPriority() {
        #expect(style.look(kind: "bench", detail: nil, named: false, z: 19)?.lowPriority == true)
        #expect(style.look(kind: "wayside_cross", detail: nil, named: false, z: 17)?.lowPriority == true)
        #expect(style.look(kind: "alpine_hut", detail: nil, named: true, z: 14)?.lowPriority == false)
        #expect(style.look(kind: "fuel", detail: nil, named: true, z: 17)?.lowPriority == false)
    }

    /// Carto draws 465 kinds of shop and has icons for 84: the rest are a
    /// purple dot.
    @Test("a shop Carto has no icon for is a dot in the shops' purple")
    func shopWithoutIcon() throws {
        let icon = try #require(style.look(kind: "tattoo", detail: nil, named: true, z: 18)?.icons.first)

        #expect(icon.asset == nil)
        #expect(icon.fill == VectorTileStyle.color("#AC39AC"))
    }

    /// Carto draws a vending machine only for the few things it sells that a
    /// passer-by needs, and the archive does not say what one sells.
    @Test("a kind Carto does not draw from what the archive keeps has no look")
    func undrawnKinds() {
        #expect(style.look(kind: "vending_machine", detail: nil, named: true, z: 19) == nil)
        #expect(style.look(kind: "no_such_kind", detail: nil, named: true, z: 19) == nil)
    }

    // MARK: Helpers

    private let iconSize = CGSize(width: 28, height: 28)

    private struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
    }

    /// The pixels of `image` the icon covers, unpremultiplied.
    private func opaquePixels(of image: CGImage) -> [Pixel] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
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
        return stride(from: 0, to: bytes.count, by: 4).compactMap { index in
            guard bytes[index + 3] == UInt8.max else { return nil }
            return Pixel(red: Int(bytes[index]), green: Int(bytes[index + 1]), blue: Int(bytes[index + 2]))
        }
    }
}
