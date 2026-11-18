//
//  VectorTileLineLabelsTests.swift
//  OpenHikesTests
//
//  Names along lines: how a street the archive split comes back whole, how
//  letters follow a line and stay upright, where a name is tried and placed,
//  and that a street's name is really drawn. Tiles are written by
//  `VectorTileFixture`.
//

import CoreGraphics
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Vector tile line labels")
struct VectorTileLineLabelsTests {
    private let tile = VectorTileAddress(z: 16, x: 36_236, y: 22_917)
    private let grid = VectorTileFixture.grid
    private let side = CGFloat(VectorTileRasterizer.pixelSize)
    private var bounds: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }
    private let bend = VectorTileLabelStyle.lineNameBend

    // MARK: Joining

    @Test("pieces of one street that meet end to end are joined, whichever way each was drawn")
    func piecesJoin() {
        let joined = VectorTileLineLabels.joined([
            [.zero, CGPoint(x: 10, y: 0)],
            [CGPoint(x: 20, y: 0), CGPoint(x: 10, y: 0)],
            [CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 5)],
            [CGPoint(x: 100, y: 100), CGPoint(x: 110, y: 100)],
        ])

        #expect(joined.count == 2, "three pieces make one street, and the fourth stands alone")
        #expect(joined.map(\.count).sorted() == [2, 4])
    }

    // MARK: Setting letters

    @Test("letters follow a straight line in order, level")
    func lettersAlongAStraightLine() {
        let letters = VectorTileLineLabels.letters(
            along: [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)],
            advances: [10, 10, 10],
            centeredAt: 50,
            maximumBend: bend
        )

        #expect(letters.map(\.center.x) == [40, 50, 60])
        #expect(letters.allSatisfy { $0.angle.isApproximatelyEqual(to: 0, absoluteTolerance: 1e-9) })
    }

    /// A street drawn east to west would put its name upside down; it is read
    /// along the line reversed instead.
    @Test("a line drawn leftward is read left to right, upright")
    func leftwardLineReadsUpright() {
        let letters = VectorTileLineLabels.letters(
            along: [CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)],
            advances: [10, 10, 10],
            centeredAt: 50,
            maximumBend: bend
        )

        #expect(letters.map(\.center.x) == [40, 50, 60], "the first letter is the leftmost")
        #expect(letters.allSatisfy { abs($0.angle) < .pi / 2 })
    }

    @Test("a name is not set across a sharp bend")
    func sharpBendRefuses() {
        let corner = [CGPoint(x: 0, y: 50), CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 100)]

        let letters = VectorTileLineLabels.letters(
            along: corner,
            advances: [10, 10, 10, 10],
            centeredAt: 50,
            maximumBend: bend
        )

        #expect(letters.isEmpty)
    }

    @Test("a name longer than its line is not set")
    func nameLongerThanLine() {
        let letters = VectorTileLineLabels.letters(
            along: [.zero, CGPoint(x: 20, y: 0)],
            advances: [10, 10, 10],
            centeredAt: 10,
            maximumBend: bend
        )

        #expect(letters.isEmpty)
    }

    /// Measured from the line's middle, so every tile cut from one archive
    /// tile tries the same marks, and slid no further than a quarter of the
    /// spacing either way, so names at neighbouring marks keep the spacing.
    @Test("marks stand at the middle and further along either side, each sliding a little")
    func marksFromTheMiddle() {
        let marks = VectorTileLineLabels.marks(length: 1000, width: 400, spacing: 200, step: 20)

        #expect(marks.map(\.distance) == [500, 200, 800])
        #expect(marks.first?.spots == [500, 520, 480, 540, 460])
        #expect(marks.allSatisfy { mark in mark.spots.allSatisfy { abs($0 - mark.distance) <= 50 } })
        #expect(marks.last?.spots == [800, 780, 760], "no spot runs the name off the line")
        #expect(VectorTileLineLabels.marks(length: 10, width: 20, spacing: 200, step: 5).isEmpty)
    }

    /// Hebrew and Arabic are written right to left, and a name is set one
    /// character at a time from the left: the characters go in page order.
    @Test("a right-to-left name is set in the order it stands on the page")
    func rightToLeftNames() {
        #expect(VectorTileLineLabels.visualOrder(of: "אבג") == ["ג", "ב", "א"])
        #expect(VectorTileLineLabels.visualOrder(of: "רחוב 12") == ["1", "2", " ", "ב", "ו", "ח", "ר"])
        #expect(VectorTileLineLabels.visualOrder(of: "Utca 12") == ["U", "t", "c", "a", " ", "1", "2"])
    }

    // MARK: Choosing

    @Test("named streets, paths and rivers are chosen and joined; unnamed ways and railways are not")
    func whatIsChosen() throws {
        let decoded = try VectorTileFixture.decoded([
            .init(name: "roads", features: [
                road("minor_road", "Király utca", from: (0, 2048), to: (2048, 2048)),
                road("minor_road", "Király utca", from: (2048, 2048), to: (4096, 2048)),
                road("path", "Váci utca", from: (0, 1000), to: (4096, 1000), detail: "pedestrian"),
                road("path", "Pernerweg", from: (0, 3000), to: (4096, 3000)),
                road("rail", "Westbahn", from: (0, 500), to: (4096, 500)),
                road("minor_road", nil, from: (0, 3500), to: (4096, 3500)),
            ]),
        ])

        let lines = VectorTileLineLabels.lines(in: decoded, source: tile, target: tile, language: "hu")

        #expect(Set(lines.map(\.name)) == ["Király utca", "Váci utca", "Pernerweg"])
        #expect(lines.first { $0.name == "Király utca" }?.points.count == 3, "the two pieces came back as one street")
        #expect(lines.first { $0.name == "Váci utca" }?.category == .minorRoad, "a pedestrian street is a street")
        #expect(lines.first { $0.name == "Pernerweg" }?.category == .path)
    }

    /// The archive files a living street as `other`, the kind it gives every
    /// highway it has no kind for.
    @Test("a living street carries its name as a street does; other highways the archive has no kind for do not")
    func livingStreetIsNamed() throws {
        let decoded = try VectorTileFixture.decoded([
            .init(name: "roads", features: [
                road("other", "Seestraße", from: (0, 2048), to: (4096, 2048), detail: "living_street"),
                road("other", "Busspur", from: (0, 1000), to: (4096, 1000), detail: "busway"),
            ]),
        ])

        let lines = VectorTileLineLabels.lines(in: decoded, source: tile, target: tile, language: "de")

        #expect(lines.map(\.name) == ["Seestraße"])
        #expect(lines.first?.category == .minorRoad)
    }

    @Test("a side street waits for zoom 15 to carry its name")
    func sideStreetsWait() throws {
        let decoded = try VectorTileFixture.decoded([
            .init(name: "roads", features: [road("minor_road", "Király utca", from: (0, 2048), to: (4096, 2048))]),
        ])
        let wide = VectorTileAddress(z: 14, x: 9059, y: 5729)

        #expect(VectorTileLineLabels.lines(in: decoded, source: wide, target: wide, language: "hu").isEmpty)
    }

    // MARK: Placing

    @Test("a long street carries its name, more than once")
    func longStreetRepeats() {
        let street = VectorTileLineLabels.NamedLine(
            category: .minorRoad,
            name: "Utca",
            points: [CGPoint(x: -500, y: 256), CGPoint(x: 712, y: 256)]
        )
        let layout = VectorTileLineLabels.Layout(
            [street],
            z: tile.z,
            unit: 2,
            bounds: bounds,
            occupied: [],
            language: "hu"
        )

        #expect(layout.count >= 2)
    }

    /// A line's marks are measured from its middle, which lies on the tile
    /// beside: that tile names it.
    @Test("a mark outside the tile is left to the tile it stands on")
    func marksOutsideAreLeft() {
        let street = VectorTileLineLabels.NamedLine(
            category: .minorRoad,
            name: "Utca",
            points: [CGPoint(x: 400, y: 256), CGPoint(x: 700, y: 256)]
        )

        let layout = VectorTileLineLabels.Layout(
            [street],
            z: tile.z,
            unit: 2,
            bounds: bounds,
            occupied: [],
            language: "hu"
        )

        #expect(layout.count == 0)
    }

    @Test("a street's name stays off the room a point's name took")
    func pointNamesComeFirst() {
        let line = VectorTileLineLabels.NamedLine(
            category: .minorRoad,
            name: "Utca",
            points: [CGPoint(x: 200, y: 256), CGPoint(x: 312, y: 256)]
        )

        let free = VectorTileLineLabels.Layout([line], z: tile.z, unit: 2, bounds: bounds, occupied: [], language: "hu")
        let blocked = VectorTileLineLabels.Layout(
            [line],
            z: tile.z,
            unit: 2,
            bounds: bounds,
            occupied: [CGRect(x: 150, y: 200, width: 212, height: 112)],
            language: "hu"
        )

        #expect(free.count == 1)
        #expect(blocked.count == 0)
    }

    // MARK: Drawing

    @Test("a street's name is drawn in ink along it")
    func streetNameIsDrawn() throws {
        let street = road("minor_road", "Király utca", from: (0, 2048), to: (4096, 2048))
        let nameless = road("minor_road", nil, from: (0, 2048), to: (4096, 2048))
        let named = [land, .init(name: "roads", features: [street])]
        let unnamed = [land, .init(name: "roads", features: [nameless])]

        #expect(try darkPixels(named) > 0)
        #expect(try darkPixels(unnamed) == 0)
    }

    // MARK: Helpers

    private var land: VectorTileFixture.Layer {
        .init(name: "earth", features: [
            .init(
                type: .polygon,
                properties: ["kind": .string("earth")],
                geometry: VectorTileFixture.rectangle(x: 0...grid, y: 0...grid)
            ),
        ])
    }

    private func road(
        _ kind: String,
        _ name: String?,
        from start: (Int, Int),
        to end: (Int, Int),
        detail: String? = nil
    ) -> VectorTileFixture.Feature {
        var properties: [String: VectorTileFixture.Value] = ["kind": .string(kind)]
        if let name { properties["name"] = .string(name) }
        if let detail { properties["kind_detail"] = .string(detail) }
        return .init(type: .line, properties: properties, geometry: VectorTileFixture.line([start, end]))
    }

    /// Pixels along the middle row darker than any road or fill the style
    /// uses: the ink of a name.
    private func darkPixels(_ layers: [VectorTileFixture.Layer]) throws -> Int {
        let decoded = try VectorTileFixture.decoded(layers, language: "hu")
        let image = try #require(VectorTileRasterizer.image(
            of: decoded,
            from: tile,
            drawing: tile,
            language: "hu",
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
        let middle = image.height / 2
        let ink = 100
        var count = 0
        for y in (middle - 8)..<(middle + 8) {
            for x in 0..<width where Int(pixels[(y * width + x) * 4]) < ink {
                count += 1
            }
        }
        return count
    }
}
