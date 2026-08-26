//
//  ColorHexTests.swift
//  OpenHikesSharedTests
//
//  The package's `Color(hex:)` is a deliberate copy of the app target's, and
//  its own doc claims it "mirrors the app target's own `Color.init?(hex:)`
//  exactly". Nothing verified that until now: the app's suite
//  (`RouteAppearanceTests`) checks the app's copy through `hexRGBA`, which is
//  the one half this package does not carry, so the two could drift without a
//  single test going red.
//
//  A widget reads `Hike.tintHex` and nothing else, so a drift here is not a
//  crash — it is a route drawn in the wrong colour on someone's Home Screen,
//  which is exactly the class of bug no one reports.
//

import Foundation
@testable import OpenHikesShared
import SwiftUI
import Testing

@Suite("Shared colour parsing")
struct ColorHexTests {
    /// The six-digit form the app writes for a fully opaque tint.
    @Test("six digits parse as the sRGB colour they name", arguments: [
        ("#FF0000", 1.0, 0.0, 0.0),
        ("#00FF00", 0.0, 1.0, 0.0),
        ("#0000FF", 0.0, 0.0, 1.0),
        ("#000000", 0.0, 0.0, 0.0),
        ("#FFFFFF", 1.0, 1.0, 1.0),
    ])
    func parsesSixDigits(hex: String, red: Double, green: Double, blue: Double) throws {
        let parsed = try #require(Color(hex: hex))
        #expect(parsed == Color(.sRGB, red: red, green: green, blue: blue, opacity: 1))
    }

    /// `Hike.randomTintHex` produces `#RRGGBBAA`, so the eight-digit form is
    /// the one the widget actually receives.
    @Test("eight digits carry their alpha through")
    func parsesEightDigits() throws {
        let parsed = try #require(Color(hex: "#34C75980"))
        #expect(
            parsed == Color(
                .sRGB,
                red: 0x34 / 255,
                green: 0xC7 / 255,
                blue: 0x59 / 255,
                opacity: 0x80 / 255
            )
        )
    }

    /// The app writes the leading `#`; a hand-edited store or a future writer
    /// might not, and both halves of the duplicated parser accept either.
    @Test("the leading hash is optional")
    func hashIsOptional() throws {
        let withHash = try #require(Color(hex: "#34C759"))
        let without = try #require(Color(hex: "34C759"))
        #expect(withHash == without)
    }

    @Test("surrounding whitespace is trimmed rather than refused")
    func trimsWhitespace() throws {
        let padded = try #require(Color(hex: "  #34C759\n"))
        #expect(padded == Color(hex: "#34C759"))
    }

    /// A tint that cannot be parsed has to come back `nil` so the widget can
    /// fall back, rather than resolving to some arbitrary colour.
    @Test("anything that is not six or eight hex digits is refused", arguments: [
        "",
        "#",
        "#FFF",
        "#FFFFF",
        "#FFFFFFF",
        "#FFFFFFFFF",
        "#GGGGGG",
        "not a colour",
    ])
    func refusesMalformed(hex: String) {
        #expect(Color(hex: hex) == nil)
    }

    /// The tint the widget ships in its own placeholder snapshot
    /// (`OpenWidget/TrailWidgetPlaceholder.swift`), which is the one string
    /// this parser is guaranteed to be handed on a fresh install — before any
    /// hike has been selected and before `SharedStore` holds anything.
    @Test("the widget's placeholder tint parses")
    func parsesWidgetPlaceholderTint() {
        #expect(Color(hex: "#34C759") != nil)
    }
}
