//
//  VectorTileDarkening.swift
//  OpenHikes
//
//  The dark map's color for one of OpenStreetMap Carto's that its palette
//  does not name (`VectorTileDarkPalette.swift`): the same hue, as light as
//  the first was dark. Worked out in Oklab, where a step in lightness looks
//  the same size whatever the hue, so a green and a purple that Carto draws
//  equally dark come out equally light.
//
//  What a color is put down as decides how light. The ground and whatever
//  fills an area stay within a narrow dark range, so that no field or car
//  park outshines the names on it: Carto's lightest ground is the darkest
//  here. A line, an icon or a name is read against that ground, so its range
//  is wide: Carto's black is nearly white here, and a pale gray, which Carto
//  uses for what matters least, is a dim one.
//

import Foundation

nonisolated enum VectorTileDarkening {
    /// The dark map's `0xRRGGBB` for Carto's `rgb` put down as `role`.
    static func darkened(_ rgb: UInt32, as role: VectorTilePalette.Role) -> UInt32 {
        let carto = Oklch(rgb: rgb)
        let range = Self.range(of: role)
        // Carto's white is the range's darkest, and its black the lightest.
        let lightness = range.darkest + (range.lightest - range.darkest) * pow(1 - carto.lightness, range.bend)
        return Oklch(lightness: lightness, chroma: carto.chroma * range.chroma, hue: carto.hue).rgb
    }

    /// How light a role's colors are on the dark map.
    private struct Range {
        /// What Carto's white comes out as, and its black.
        let darkest: Double
        let lightest: Double
        /// Above one, the mid tones stay near the darkest; below it, they
        /// are lifted towards the lightest.
        let bend: Double
        /// How much of its strength a color keeps.
        let chroma: Double
    }

    private static func range(of role: VectorTilePalette.Role) -> Range {
        switch role {
        case .fill, .halo, .surface: ground
        case .casing, .icon, .line, .pattern, .text: ink
        }
    }

    private static let ground = Range(
        darkest: groundDarkest,
        lightest: groundLightest,
        bend: groundBend,
        chroma: groundChroma
    )
    private static let ink = Range(darkest: inkDarkest, lightest: inkLightest, bend: inkBend, chroma: inkChroma)

    // Oklab lightness, from none to one. The land is the palette's own
    // 0.23 or so, and a name's white 0.94.
    private static let groundDarkest = 0.21
    private static let groundLightest = 0.62
    private static let groundBend = 0.82
    private static let groundChroma = 0.72
    private static let inkDarkest = 0.32
    private static let inkLightest = 0.93
    private static let inkBend = 0.74
    private static let inkChroma = 0.9
}

/// A color as its lightness, its strength and its hue, in Oklab's
/// cylinder (Björn Ottosson's, 2020).
nonisolated private struct Oklch {
    let lightness: Double
    let chroma: Double
    /// In radians.
    let hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    init(rgb: UInt32) {
        let linear = Self.channels(of: rgb).map(Self.linear)
        let cones = Self.conesFromLinear.map { row in cbrt(zip(row, linear).reduce(0) { $0 + $1.0 * $1.1 }) }
        let lab = Self.labFromCones.map { row in zip(row, cones).reduce(0) { $0 + $1.0 * $1.1 } }
        lightness = lab[0]
        chroma = hypot(lab[1], lab[2])
        hue = atan2(lab[2], lab[1])
    }

    /// The nearest sRGB color: the same lightness and hue, with as much of
    /// the strength as sRGB can show at that lightness.
    var rgb: UInt32 {
        var low = 0.0
        var high = chroma
        guard Self.linearChannels(lightness: lightness, chroma: high, hue: hue).contains(where: Self.isOutside) else {
            return Self.packed(Self.linearChannels(lightness: lightness, chroma: high, hue: hue))
        }
        for _ in 0..<Self.halvings {
            let middle = (low + high) / 2
            if Self.linearChannels(lightness: lightness, chroma: middle, hue: hue).contains(where: Self.isOutside) {
                high = middle
            } else {
                low = middle
            }
        }
        return Self.packed(Self.linearChannels(lightness: lightness, chroma: low, hue: hue))
    }

    private static func linearChannels(lightness: Double, chroma: Double, hue: Double) -> [Double] {
        let lab = [lightness, chroma * cos(hue), chroma * sin(hue)]
        let cones = conesFromLab.map { row in pow(zip(row, lab).reduce(0) { $0 + $1.0 * $1.1 }, 3) }
        return linearFromCones.map { row in zip(row, cones).reduce(0) { $0 + $1.0 * $1.1 } }
    }

    private static func isOutside(_ channel: Double) -> Bool {
        channel < -gamutSlack || channel > 1 + gamutSlack
    }

    private static func packed(_ linear: [Double]) -> UInt32 {
        let channels = linear.map { CGFloat(encoded(min(max($0, 0), 1))) }
        return VectorTilePalette.packed(red: channels[0], green: channels[1], blue: channels[2])
    }

    private static func channels(of rgb: UInt32) -> [Double] {
        [VectorTilePalette.redShift, VectorTilePalette.greenShift, 0].map { shift in
            Double((rgb >> shift) & VectorTilePalette.channelMask) / Double(VectorTilePalette.channelMask)
        }
    }

    /// sRGB's transfer curve, and back.
    private static func linear(_ encoded: Double) -> Double {
        encoded <= encodedKnee ? encoded / kneeSlope : pow((encoded + curveOffset) / (1 + curveOffset), curveGamma)
    }

    private static func encoded(_ linear: Double) -> Double {
        linear <= linearKnee ? linear * kneeSlope : (1 + curveOffset) * pow(linear, 1 / curveGamma) - curveOffset
    }

    private static let encodedKnee = 0.04045
    private static let linearKnee = 0.0031308
    private static let kneeSlope = 12.92
    private static let curveOffset = 0.055
    private static let curveGamma = 2.4
    /// How far outside sRGB a channel may fall and still count as in it.
    private static let gamutSlack = 0.0005
    /// Halvings of the strength that find the most sRGB can show.
    private static let halvings = 12

    // Oklab's matrices, as published: linear sRGB to the cones' responses
    // and those, cube-rooted, to Lab; and both back. Thirty-three figures
    // that have no names but their places in these.
    // swiftlint:disable no_magic_numbers
    private static let conesFromLinear: [[Double]] = [
        [0.4122214708, 0.5363325363, 0.0514459929],
        [0.2119034982, 0.6806995451, 0.1073969566],
        [0.0883024619, 0.2817188376, 0.6299787005],
    ]
    private static let labFromCones: [[Double]] = [
        [0.2104542553, 0.7936177850, -0.0040720468],
        [1.9779984951, -2.4285922050, 0.4505937099],
        [0.0259040371, 0.7827717662, -0.8086757660],
    ]
    private static let conesFromLab: [[Double]] = [
        [1, 0.3963377774, 0.2158037573],
        [1, -0.1055613458, -0.0638541728],
        [1, -0.0894841775, -1.2914855480],
    ]
    private static let linearFromCones: [[Double]] = [
        [4.0767416621, -3.3077115913, 0.2309699292],
        [-1.2684380046, 2.6097574011, -0.3413193965],
        [-0.0041960863, -0.7034186147, 1.7076147010],
    ]
    // swiftlint:enable no_magic_numbers
}
