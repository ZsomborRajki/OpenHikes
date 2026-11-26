//
//  VectorTileDarkeningTests.swift
//  OpenHikesTests
//
//  The dark map's color for one of Carto's that its palette does not name:
//  light where Carto's was dark and dark where it was light, in the same
//  hue, within the range its role keeps.
//

import CoreGraphics
@testable import OpenHikes
import Testing

@Suite("Vector tile darkening")
struct VectorTileDarkeningTests {
    private static let grays: [UInt32] = [0x000000, 0x444444, 0x888888, 0xCCCCCC, 0xFFFFFF]

    private func channels(_ rgb: UInt32) -> (red: Int, green: Int, blue: Int) {
        (Int((rgb >> 16) & 0xFF), Int((rgb >> 8) & 0xFF), Int(rgb & 0xFF))
    }

    @Test("the lighter Carto's color, the darker the dark map's", arguments: VectorTilePalette.Role.allCases)
    func lightnessIsTurnedOver(role: VectorTilePalette.Role) {
        let darkened = Self.grays.map { channels(VectorTileDarkening.darkened($0, as: role)).green }
        #expect(darkened == darkened.sorted(by: >), "\(darkened)")
        #expect(Set(darkened).count == darkened.count, "no two grays come out alike")
    }

    @Test("a gray stays a gray")
    func graysKeepNoColor() {
        for gray in Self.grays {
            let darkened = channels(VectorTileDarkening.darkened(gray, as: .line))
            #expect(abs(darkened.red - darkened.green) <= 1 && abs(darkened.green - darkened.blue) <= 1)
        }
    }

    @Test("Carto's white ground is dark, and its black ink nearly white")
    func theEnds() {
        let ground = channels(VectorTileDarkening.darkened(0xFFFFFF, as: .fill))
        #expect(ground.green < 0x30)
        let ink = channels(VectorTileDarkening.darkened(0x000000, as: .text))
        #expect(ink.green > 0xD8)
    }

    /// No field or car park may outshine the names on it, whatever Carto
    /// fills it with.
    @Test("whatever fills an area stays darker than whatever is read on it")
    func groundStaysUnderInk() {
        let fills: [UInt32] = [0xF2EFE9, 0xADD19E, 0xFFD6D1, 0x88E0BE, 0xC5C3C3, 0xFFF1BA]
        let inks: [UInt32] = [0x222222, 0x000000, 0x734A08, 0x0092DA, 0xAC39AC, 0x008000]
        let lightestGround = fills.map { channels(VectorTileDarkening.darkened($0, as: .fill)) }
            .map { max($0.red, $0.green, $0.blue) }
            .max() ?? 0
        let darkestInk = inks.map { channels(VectorTileDarkening.darkened($0, as: .icon)) }
            .map { max($0.red, $0.green, $0.blue) }
            .min() ?? 0
        #expect(lightestGround < darkestInk)
    }

    @Test("a color keeps its hue")
    func hueIsKept() {
        let green = channels(VectorTileDarkening.darkened(0x008000, as: .line))
        #expect(green.green > green.red && green.green > green.blue)
        let red = channels(VectorTileDarkening.darkened(0xBF0000, as: .icon))
        #expect(red.red > red.green && red.red > red.blue)
        let blue = channels(VectorTileDarkening.darkened(0xAAD3DF, as: .fill))
        #expect(blue.blue > blue.red)
    }

    /// The strongest colors there are leave sRGB when their lightness moves,
    /// and are brought back into it rather than wrapped round.
    @Test("a color sRGB cannot show at its new lightness is brought into it, in its own hue")
    func gamut() {
        let blue = channels(VectorTileDarkening.darkened(0x0000FF, as: .text))
        #expect(blue.blue == 0xFF || blue.blue > blue.red, "still a blue")
        #expect(blue.red > 0x40, "and light enough to read")
        let yellow = channels(VectorTileDarkening.darkened(0xFFFF00, as: .fill))
        #expect(yellow.blue < yellow.red, "still a yellow")
    }
}
