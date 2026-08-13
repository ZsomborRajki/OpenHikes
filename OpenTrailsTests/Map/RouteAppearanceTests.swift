//
//  RouteAppearanceTests.swift
//  OpenTrailsTests
//
//  A hike's tint is picked with a colour well and stored as a hex string, so
//  it survives a relaunch and can be read by the widget. That
//  round trip is the only thing standing between "the user chose a colour"
//  and "the route is drawn in it" — including the alpha, which is deliberately
//  applied to the map line alone while every other surface uses the opaque
//  form.
//

@testable import OpenTrails
import SwiftUI
import Testing

@Suite("Route appearance")
struct RouteAppearanceTests {
    @Test("six-digit hex parses as a fully opaque colour", arguments: [
        "#34C759", "34C759", "  #34C759  ", "#000000", "#FFFFFF"
    ])
    func parsesSixDigits(hex: String) throws {
        let color = try #require(Color(hex: hex))
        #expect(color.hexRGBA.hasSuffix("FF"))
    }

    @Test("eight-digit hex carries its alpha through")
    func parsesEightDigits() throws {
        let color = try #require(Color(hex: "#34C75980"))
        #expect(color.hexRGBA == "#34C75980")
    }

    /// The stored string is what a relaunch reads back, so a colour has to
    /// survive the trip unchanged.
    @Test("a colour round trips through its stored form", arguments: [
        "#34C759FF", "#FF0000FF", "#0000FF80", "#123456AB", "#FFFFFF00"
    ])
    func roundTrip(hex: String) throws {
        let color = try #require(Color(hex: hex))
        #expect(color.hexRGBA == hex)
        let reparsed = try #require(Color(hex: color.hexRGBA))
        #expect(reparsed.hexRGBA == hex)
    }

    /// Everything except the map line reads the opaque form, so a
    /// half-transparent route still gets a legible row icon and chart.
    @Test("the opaque form keeps the colour and drops the transparency")
    func opaqueDropsAlpha() throws {
        let translucent = try #require(Color(hex: "#34C75910"))
        #expect(translucent.opaque.hexRGBA == "#34C759FF")
    }

    /// Garbage in a stored tint must not produce a colour — `Hike.tint` falls
    /// back to green, which is a visible-but-harmless outcome; a crash or a
    /// black route would not be.
    @Test("malformed hex is refused", arguments: [
        "", "#", "#12345", "#1234567", "#GGGGGG", "not a colour", "#34C759 34C759"
    ])
    func refusesMalformedHex(hex: String) {
        #expect(Color(hex: hex) == nil)
    }

    /// The generated per-hike tint has to be storable — it goes straight into
    /// `Hike.tintHex` on import.
    /// Seeded, so a hue that round-trips wrong is reproducible: re-run with
    /// `OPENTRAILS_TEST_SEED` set to the seed quoted below and this sweep
    /// generates exactly the same tints.
    @Test("a generated tint is a valid stored tint")
    func randomTintIsStorable() throws {
        var generator = SeededGenerator()
        let seed = generator.seed
        for _ in 0..<50 {
            let hex = Hike.randomTintHex(using: &generator)
            #expect(hex.count == 9, "expected #RRGGBBAA, got \(hex) (seed \(seed))")
            let color = try #require(Color(hex: hex), "seed \(seed)")
            #expect(color.hexRGBA == hex, "seed \(seed)")
            #expect(hex.hasSuffix("FF"), "a generated tint should be fully opaque (seed \(seed))")
        }
    }

    /// The map rebuilds its polyline when this changes, so it must change for
    /// a new selection and for nothing else. The coordinates are deliberately
    /// ignored (they only ever change together with the id), and so is the
    /// route's appearance — that lives in `RouteStyle` and reaches the map
    /// without a redraw at all.
    @Test("a displayed route compares by identity alone")
    func displayedRouteEquality() {
        let id = UUID()
        let coordinates = Fixture.coordinates(Fixture.ridgeRoute)
        let base = DisplayedRoute(id: id, coordinates: coordinates)

        #expect(base == DisplayedRoute(id: id, coordinates: coordinates))
        #expect(base != DisplayedRoute(id: UUID(), coordinates: coordinates))
        // Same hike: not a redraw, whatever the coordinates say.
        #expect(base == DisplayedRoute(id: id, coordinates: []))
    }
}
