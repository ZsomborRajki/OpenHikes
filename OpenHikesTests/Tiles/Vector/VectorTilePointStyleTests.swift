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

    /// Carto draws stops in a layer of their own, `stations.mss`, as a square
    /// in its station blue that grows with the zoom.
    @Test("a station is a blue square from zoom 12, named in bold from 14; halts and tram stops come later")
    func stations() throws {
        let look = { (kind: String, z: Int) in style.look(kind: kind, detail: nil, named: true, z: z) }
        let early = try #require(look("station", 12))
        let named = try #require(look("station", 14))
        let near = try #require(look("station", 15))

        #expect(early.isStation)
        #expect(early.icons.first?.asset == "carto-square")
        #expect(early.icons.first?.fill == VectorTileStyle.color("#7981B0"))
        #expect(early.icons.first?.size == CGSize(width: 4, height: 4))
        #expect(early.text == nil)
        #expect(named.text?.face == .bold)
        #expect(near.icons.first?.size == CGSize(width: 9, height: 9))
        #expect(near.text?.size == 11)
        #expect(look("halt", 12) == nil)
        #expect(look("halt", 15)?.text?.face == .bold)
        #expect(look("tram_stop", 13) == nil)
        #expect(look("tram_stop", 14)?.text == nil)
        #expect(look("tram_stop", 16)?.text?.face == .regular)
        #expect(look("fuel", 17)?.isStation == false)
    }

    /// Carto writes an entrance's `ref` by it from zoom 19, which the
    /// archive does not keep.
    @Test("a subway entrance is Carto's entrance icon from zoom 18, with no text, placed after the stations")
    func subwayEntrance() throws {
        #expect(style.look(kind: "subway_entrance", detail: nil, named: true, z: 17) == nil)
        let entrance = try #require(style.look(kind: "subway_entrance", detail: nil, named: true, z: 19))
        let station = try #require(style.look(kind: "station", detail: nil, named: true, z: 19)?.stationOrder)

        #expect(entrance.icons.first?.asset == "carto-amenity-entrance")
        #expect(entrance.icons.first?.fill == VectorTileStyle.color("#0092DA"))
        #expect(entrance.text == nil)
        #expect(try #require(entrance.stationOrder) > station)
    }

    @Test("benches and wayside crosses claim room last; huts and fuel do not")
    func lowPriority() {
        #expect(style.look(kind: "bench", detail: nil, named: false, z: 19)?.lowPriority == true)
        #expect(style.look(kind: "wayside_cross", detail: nil, named: false, z: 17)?.lowPriority == true)
        #expect(style.look(kind: "alpine_hut", detail: nil, named: true, z: 14)?.lowPriority == false)
        #expect(style.look(kind: "fuel", detail: nil, named: true, z: 17)?.lowPriority == false)
    }

    /// The vector extras carry an information point's type, which Carto
    /// draws it by, and the basemap's own information points have none.
    @Test("an information point is drawn by its type, and not without one")
    func informationByType() {
        let icon = { (type: String?) in
            style.look(kind: "information", detail: type, named: true, z: 19)?.icons.first?.asset
        }

        #expect(icon("guidepost") == "carto-tourism-guidepost")
        #expect(icon("board") == "carto-tourism-board")
        #expect(icon(nil) == nil)
    }

    /// Carto's query writes the height of a guidepost alone among the
    /// information points, and the extras carry every one's `ele`.
    @Test("of the information points, only a guidepost is labeled with its height")
    func onlyGuidepostsShowTheirHeight() {
        let showsHeight = { (type: String) in
            style.look(kind: "information", detail: type, named: true, z: 19)?.showsElevation
        }

        #expect(showsHeight("guidepost") == true)
        #expect(showsHeight("board") == false)
        #expect(showsHeight("office") == false)
        #expect(showsHeight("map") == false)
    }

    /// A gate the extras bring is a barrier on a path, though an airport's
    /// gate goes by the same value.
    @Test("a gate is a barrier, and an office is Carto's office dot")
    func extrasKinds() throws {
        let gate = try #require(style.look(kind: "gate", detail: nil, named: false, z: 17))
        let office = try #require(style.look(kind: "office", detail: nil, named: true, z: 18)?.icons.first)

        #expect(gate.lowPriority)
        #expect(gate.icons.first?.asset == "carto-barrier-gate")
        #expect(office.asset == nil)
        #expect(office.fill == VectorTileStyle.color("#4863A0"))
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
