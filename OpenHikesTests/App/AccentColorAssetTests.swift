//
//  AccentColorAssetTests.swift
//  OpenHikesTests
//
//  That the app's accent colour is a colour.
//
//  `InfoPlistContractTests`' sibling, and the same class of silent failure.
//  All three colour sets in the two catalogs were Xcode's empty template — a
//  `colors` array holding one `{"idiom": "universal"}` with no `color` key at
//  all — while `project.pbxproj` named them in
//  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` as though they held
//  something. They compiled to nothing, and `assetutil --info` on the built
//  product listed only `AppIcon`.
//
//  Nothing failed. `.accentColor` simply resolved to the stock SwiftUI blue in
//  about fifteen places, several of them load-bearing for how a screen reads —
//  the default tint of every `ActionTile`, which map provider is selected, what
//  the sync row is doing — and the community map's route lines, which are
//  drawn in `UIColor.tintColor` precisely so they agree with it.
//
//  So there is nothing in Swift that refers to the asset, and no build that
//  fails without it. This is the only place it can be held.
//

import Foundation
@testable import OpenHikes
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif

@Suite("Accent colour asset")
struct AccentColorAssetTests {
    #if canImport(UIKit)
    /// The stock tint an empty colour set falls back to, which is exactly what
    /// this app shipped. Compared against rather than asserted for: the point
    /// is not that blue is wrong, it is that nobody chose it.
    private static let stockBlue = UIColor.systemBlue

    private func accent() throws -> UIColor {
        try #require(
            UIColor(named: "AccentColor"),
            "the app bundle carries no AccentColor asset"
        )
    }

    private func resolved(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UIColor {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    /// Present at all, which is the half that was missing.
    @Test("the accent colour exists")
    func accentExists() throws {
        _ = try accent()
    }

    /// Appearance-aware, like everything else in this app. A single value for
    /// both appearances is a colour that was filled in rather than chosen.
    @Test("the accent colour has separate light and dark values")
    func accentIsAppearanceAware() throws {
        let accent = try accent()
        #expect(resolved(accent, .light) != resolved(accent, .dark))
    }

    /// The route green the app already defaults to. `Hike.defaultTintHex` is
    /// the source: the community map draws shared routes in
    /// `UIColor.tintColor` so that a route line and the app's tint agree, and
    /// they can only agree if this is that colour.
    @Test("the light accent is the route tint the app already defaults to")
    func accentMatchesTheRouteTint() throws {
        let routeTint = try #require(Color(hex: Hike.defaultTintHex))
        let expected = UIColor(routeTint)
        let accent = resolved(try accent(), .light)

        var (red, green, blue): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        var (wantRed, wantGreen, wantBlue): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        accent.getRed(&red, green: &green, blue: &blue, alpha: nil)
        expected.getRed(&wantRed, green: &wantGreen, blue: &wantBlue, alpha: nil)

        #expect(abs(red - wantRed) < 0.002)
        #expect(abs(green - wantGreen) < 0.002)
        #expect(abs(blue - wantBlue) < 0.002)
    }

    /// The assertion that would have caught the original bug, in both
    /// appearances: an empty colour set resolves to the system blue, and so
    /// did every `.accentColor` in the app.
    @Test("the accent is not the stock blue an empty colour set falls back to", arguments: [
        UIUserInterfaceStyle.light, .dark,
    ])
    func accentIsNotStockBlue(style: UIUserInterfaceStyle) throws {
        #expect(resolved(try accent(), style) != resolved(Self.stockBlue, style))
    }
    #endif
}
