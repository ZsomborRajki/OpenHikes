//
//  ContentSurfaceTests.swift
//  OpenHikesTests
//
//  The one property ``Color/contentSurface`` exists for.
//
//  It is what content inside the map sheet is read against, and the sheet is
//  presented on clear glass over live map imagery. Every value it replaced was
//  a low alpha chosen against a backdrop that iOS 27 made transparent — so a
//  surface that is itself even slightly transparent is the same bug with an
//  extra step, and a surface that does not change with the appearance is a
//  light card in a dark app.
//
//  Two assertions, and both of them are about the colour rather than about any
//  view that uses it: the views spend it through `background`, which nothing
//  here can read back.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Content surface")
struct ContentSurfaceTests {
    #if canImport(UIKit)
    private func resolved(_ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(Color.contentSurface)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func alpha(of color: UIColor) -> CGFloat {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        color.getWhite(&white, alpha: &alpha)
        return alpha
    }
    #endif

    /// Opaque, in both appearances.
    ///
    /// The point of the type. A chart, a tinted row and a stacked bar are all
    /// laid on this so they stop being read against map tiles; anything less
    /// than fully opaque lets the tiles back in.
    @Test("the surface is opaque in both appearances")
    func surfaceIsOpaque() {
        #if canImport(UIKit)
        #expect(alpha(of: resolved(.light)) == 1)
        #expect(alpha(of: resolved(.dark)) == 1)
        #endif
    }

    /// And it is the system's surface rather than one fixed colour, so the
    /// card is dark in a dark app.
    @Test("the surface follows the appearance")
    func surfaceFollowsTheAppearance() {
        #if canImport(UIKit)
        #expect(
            resolved(.light) != resolved(.dark),
            "a fixed colour here would be a white card in dark mode"
        )
        #endif
    }
}
