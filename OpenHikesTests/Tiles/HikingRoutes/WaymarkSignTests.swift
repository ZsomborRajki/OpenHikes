//
//  WaymarkSignTests.swift
//  OpenHikesTests
//
//  Which sign a route gets, what it is called when it has no waymark, how
//  wide it is, and that it is drawn in its colours: a red-white-red sign
//  drawn into a bitmap is read back pixel by pixel.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import Testing

@Suite("Waymark sign")
struct WaymarkSignTests {
    @Test("a route's waymark is its sign, and its number stands in where it has none")
    func whichSign() throws {
        let symbol = try #require(OSMCSymbol(tag: "red:white:red_bar"))
        #expect(WaymarkSign(tags: ["osmc:symbol": "red:white:red_bar", "ref": "443"])?.content == .symbol(symbol))
        #expect(WaymarkSign(tags: ["network": "rwn", "ref": "Arn"])?.content == .reference("Arn"))
        #expect(WaymarkSign(tags: ["network": "lwn", "ref": "13"])?.content == .reference("13"))
        #expect(WaymarkSign(tags: ["network": "nwn"]) == nil)
        #expect(WaymarkSign(tags: ["network": "iwn", "ref": "  "]) == nil)
    }

    @Test("a sign is framed by its route's network, and a route outside the scheme is a local one")
    func network() {
        #expect(WaymarkSign(tags: ["network": "iwn", "ref": "E4"])?.network == .international)
        #expect(WaymarkSign(tags: ["ref": "7"])?.network == .local)
        #expect(WaymarkSign(tags: ["ref": "7"]) == WaymarkSign(tags: ["network": "lwn", "ref": "7"]))
        #expect(WaymarkSign(tags: ["network": "rwn", "ref": "7"]) != WaymarkSign(tags: ["network": "lwn", "ref": "7"]))
    }

    @Test(
        "a route with no number is called by its name: whole when short, by its capitals, or by its start",
        arguments: [
            (["ref": "VA A44"], "VAA44"),
            (["ref": "01 A"], "01A"),
            (["name": "Arn"], "Arn"),
            (["name": "Salzburger Almenweg"], "SA"),
            (["name": "Tauernhöhenweg 502"], "T502"),
            (["name": "Viehkogelrunde"], "Viehk"),
            (["name": "kleine runde"], "klein"),
        ] as [([String: String], String)]
    )
    func reference(tags: [String: String], expected: String) {
        #expect(WaymarkSign.reference(from: tags) == expected)
    }

    @Test("a sign is square, and as wide as its text needs")
    func size() throws {
        let plain = try #require(WaymarkSign(tags: ["osmc:symbol": "red:white:red_bar"]))
        let numbered = try #require(WaymarkSign(tags: ["osmc:symbol": "red:white:red_bar:443A:black"]))
        #expect(plain.size == CGSize(width: WaymarkSign.side, height: WaymarkSign.side))
        #expect(numbered.size.height == WaymarkSign.side)
        #expect(numbered.size.width > WaymarkSign.side)
    }

    @Test("red-white-red is drawn white above and below a red bar, inside a frame of its network's colour")
    func drawsTheBar() throws {
        let sign = try #require(WaymarkSign(tags: ["osmc:symbol": "red:white:red_bar", "network": "nwn"]))
        let scale = 10.0
        let side = Int(WaymarkSign.side * scale)
        let context = try #require(CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // A y-down context, one unit a tile pixel, the sign's centre in the
        // middle.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: WaymarkSign.side / 2, y: WaymarkSign.side / 2)
        sign.draw(in: context)
        let image = try #require(context.makeImage())
        let middle = Self.pixel(in: image, x: side / 2, y: side / 2)
        let top = Self.pixel(in: image, x: side / 2, y: side / 5)
        let frame = Self.pixel(in: image, x: side / 2, y: Int(WaymarkSign.frameWidth * scale / 2))
        #expect(middle.red > 200 && middle.green < 80, "the bar is red")
        #expect(top.red > 200 && top.green > 200 && top.blue > 200, "above it is white")
        #expect(frame.blue > 200 && frame.red < 80, "the frame is a national route's blue")
    }

    private static func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        let offset = y * image.bytesPerRow + x * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}
