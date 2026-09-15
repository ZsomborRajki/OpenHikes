//
//  RouteTintTests.swift
//  OpenHikesTests
//
//  The palette every route colour comes out of.
//
//  Two halves worth holding still. ``RouteTint/random(using:)`` is what a hike
//  being imported gets, and its answer is written to ``Hike/tintHex`` and never
//  computed again — so what matters there is that every hue it can hand out is
//  legible. ``RouteTint/stable(for:)`` is what a community listing gets, and
//  *its* answer is recomputed on every search, every redraw and every launch —
//  so what matters there is that the answer never changes.
//
//  The determinism test is the one with teeth. The obvious spelling of
//  "a colour from a key" is `key.hashValue`, which Swift seeds per process:
//  it passes every assertion that can be written inside one run of a test
//  bundle and gives a hiker a differently coloured map every time they open
//  the app. The golden below is what catches that, because it is the only
//  thing here that a second process had to agree with.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Route tint")
struct RouteTintTests {
    /// Every id a page of curated results can hold looks like this: one prefix
    /// and a relation number, differing in the last digit or two.
    private static func curatedIDs(_ range: ClosedRange<Int64>) -> [String] {
        range.map { CommunityIdentity.curated(relationID: $0) }
    }

    /// What the palette promises about every colour it hands out.
    private struct Components {
        let hue: CGFloat
        let saturation: CGFloat
        let brightness: CGFloat
        let alpha: CGFloat
    }

    /// How far from the palette's own figures a round trip through `UIColor`
    /// is allowed to land.
    private static let componentTolerance: CGFloat = 0.01
    /// A uniform spread of hues averages a quarter turn between neighbours.
    /// Anything above a sixth is nowhere near the gradient this rules out, and
    /// is five standard errors clear of what fifty uniform draws produce.
    private static let gradientFloor = 1.0 / 6
    /// Out of a twenty-five row page. See ``aPageIsManyColours``.
    private static let distinctFloor = 23
    private static let paletteSaturation: CGFloat = 0.65
    private static let paletteBrightness: CGFloat = 0.85

    #if canImport(UIKit)
    private static func hue(of color: Color) -> CGFloat {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return hue
    }

    private func components(_ color: Color) -> Components {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Components(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
    }
    #endif

    /// The golden. A colour computed in one process, asserted in another.
    ///
    /// Recomputing FNV-1a here instead would assert only that the test agrees
    /// with itself, and would keep on passing if the implementation were
    /// swapped for `hashValue` *and* the test with it. This value was produced
    /// by a separate program and is what pins the mapping across processes,
    /// launches and devices — which is the entire contract.
    @Test("a key maps to the same colour in any process")
    func stableAcrossProcesses() {
        #expect(RouteTint.stable(for: "listing-1").hexRGBA == "#A5D94CFF")
        #expect(RouteTint.stable(for: "osm-relation-411").hexRGBA == "#4CD958FF")
    }

    /// The same thing said the way a caller would notice it: ask twice, get
    /// the same answer.
    @Test("the same key answers the same colour every time it is asked")
    func stableWithinAProcess() {
        let ids = Self.curatedIDs(1...50)
        let first = ids.map { RouteTint.stable(for: $0).hexRGBA }
        let second = ids.map { RouteTint.stable(for: $0).hexRGBA }

        #expect(first == second)
    }

    /// Consecutive relation ids are the case this has to be good at, and the
    /// case a weak hash is worst at: a valley's worth of trails are numbered
    /// next to each other, so an id-modulo-hue scheme — or any hash that does
    /// not avalanche — would hand a whole search area one shade of green.
    ///
    /// Measured as the distance around the wheel between one id's hue and the
    /// next id's, which is the thing a hiker sees. A uniform spread averages a
    /// quarter turn; a gradient would average almost nothing.
    @Test("consecutive relation ids land far apart on the wheel")
    func consecutiveIDsAreNotAGradient() {
        #if canImport(UIKit)
        let hues = Self.curatedIDs(1_000_000...1_000_049).map { Self.hue(of: RouteTint.stable(for: $0)) }
        let gaps = zip(hues, hues.dropFirst()).map { first, second in
            let apart = abs(Double(first - second))
            return min(apart, 1 - apart)
        }
        let mean = gaps.reduce(0, +) / Double(gaps.count)

        #expect(mean > Self.gradientFloor, "adjacent ids averaged \(mean) of a turn apart")
        #endif
    }

    /// The point of the whole change, said as a hiker would notice it: a page
    /// of results is not one colour.
    ///
    /// Not *every* swatch distinct, which is a stricter claim than the screen
    /// can carry. Two hues a fraction of a degree apart resolve to the same
    /// three bytes, and fifty draws from a wheel meet the birthday bound
    /// besides — the same as the file import, which has always been free to
    /// hand two hikes near-identical greens. What must not happen is a page
    /// that reads as one colour.
    @Test("a page of results is a page of colours")
    func aPageIsManyColours() {
        let ids = Self.curatedIDs(1_000_000...1_000_024)
        let swatches = Set(ids.map { RouteTint.stable(for: $0).hexRGBA })

        #expect(swatches.count >= Self.distinctFloor, "a page of \(ids.count) drew \(swatches.count) colours")
    }

    /// What the fixed saturation and brightness buy. A white glyph sits on
    /// these inside a map pin and a row's circle, and a 2-point line drawn in
    /// one has to read over a satellite tile.
    @Test("every hue comes out at the palette's saturation and brightness")
    func everyHueIsLegible() {
        #if canImport(UIKit)
        let degrees = 360
        for step in 0..<degrees {
            let parts = components(RouteTint.color(hue: Double(step) / Double(degrees)))
            #expect(
                abs(parts.saturation - Self.paletteSaturation) < Self.componentTolerance,
                "hue \(step) came out at saturation \(parts.saturation)"
            )
            #expect(
                abs(parts.brightness - Self.paletteBrightness) < Self.componentTolerance,
                "hue \(step) came out at brightness \(parts.brightness)"
            )
            #expect(parts.alpha == 1, "a route colour is never transparent on its own account")
        }
        #endif
    }

    /// The random half is the same palette, so a hike imported from a file and
    /// a trail imported from the community cannot be told apart by their
    /// colour afterwards — which is the point of there being one file.
    @Test("a random tint is a colour of the same palette")
    func randomStaysInThePalette() {
        #if canImport(UIKit)
        // The bundle's own SplitMix64, so a failure here is re-runnable
        // with `OPENHIKES_TEST_SEED` like every other sweep in the suite.
        var generator = SeededGenerator()
        for _ in 0..<200 {
            let parts = components(RouteTint.random(using: &generator))
            #expect(
                abs(parts.saturation - Self.paletteSaturation) < Self.componentTolerance,
                "seed \(generator.seed) produced saturation \(parts.saturation)"
            )
            #expect(
                abs(parts.brightness - Self.paletteBrightness) < Self.componentTolerance,
                "seed \(generator.seed) produced brightness \(parts.brightness)"
            )
        }
        #endif
    }
}
