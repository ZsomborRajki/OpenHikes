//
//  ElevationFormatTests.swift
//  OpenHikesTests
//
//  Height is a regional unit, and this is what says so.
//
//  `SpeedFormatTests`' sibling, for the third instance of the same bug. Speed
//  was pinned to km/h and the weather badge to Celsius; elevation was pinned
//  to metres, and the app drew "1,250 m" beside "3.1 mi" while the widget drew
//  "4,101 ft" for the same hike. Nothing here reads `Locale.current` — an
//  assertion that takes the machine's own region as its input agrees with
//  whatever the machine is set to, which is exactly how the original bugs
//  survived a green suite.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Elevation formatting")
struct ElevationFormatTests {
    private static func elevation(_ meters: Double, _ identifier: String) -> String {
        HikeFormat.elevation(
            Measurement(value: meters, unit: .meters),
            locale: Locale(identifier: identifier)
        )
    }

    /// Pinned as whole strings rather than as "contains ft", so that a change
    /// to the unit, the rounding or the grouping separator all have to be
    /// argued for rather than discovered.
    @Test("a US reader is given feet", arguments: [
        (1250.0, "4,101 ft"),
        (535.0, "1,755 ft"),
        (217.4382, "713 ft"),
    ])
    func americanEnglish(meters: Double, expected: String) {
        #expect(Self.elevation(meters, "en_US") == expected)
    }

    /// The UK measures a hill in feet, whatever it does with the weather — so
    /// it belongs with the US here and not with the metric list, exactly as it
    /// does for road distance and speed.
    @Test("a UK reader is given feet too", arguments: [
        (1250.0, "4,101 ft"),
        (217.4382, "713 ft"),
    ])
    func britishEnglish(meters: Double, expected: String) {
        #expect(Self.elevation(meters, "en_GB") == expected)
    }

    /// Both halves of a metric rendering: the unit *and* the grouping
    /// separator, which is a point here and a comma in Japanese despite both
    /// being metric.
    @Test("a metric reader is given metres", arguments: [
        ("de_DE", 1250.0, "1.250 m"),
        ("de_DE", 217.4382, "217 m"),
        ("ja_JP", 1250.0, "1,250 m"),
        ("ja_JP", 535.0, "535 m"),
    ])
    func metricRegions(identifier: String, meters: Double, expected: String) {
        #expect(Self.elevation(meters, identifier) == expected)
    }

    /// The invariant the bug actually broke. Whether a region wants feet is
    /// not something this suite should decide — it asks the same question the
    /// distance row asks, and requires the two answers to match. A future
    /// change to either row that leaves them disagreeing fails here.
    @Test(
        "elevation follows the same system the distance row does",
        arguments: ["en_US", "en_GB", "de_DE", "ja_JP"]
    )
    func agreesWithTheDistanceRow(identifier: String) {
        let locale = Locale(identifier: identifier)
        let distance = Measurement(value: 5000, unit: UnitLength.meters)
            .formatted(
                .measurement(width: .abbreviated, usage: .road).locale(locale)
            )
        let elevation = Self.elevation(1250, identifier)

        #expect(
            distance.contains("mi") == elevation.contains("ft"),
            "\(identifier) drew \"\(distance)\" beside \"\(elevation)\""
        )
    }

    /// The visible half of this bug: two surfaces describing the same hike in
    /// two different units. The widget got the conversion first, so this is
    /// the assertion that says the app has caught up — and the one that fails
    /// if either side is changed alone.
    @Test(
        "the app and the widget agree about the same height",
        arguments: ["en_US", "en_GB", "de_DE", "ja_JP"]
    )
    func agreesWithTheWidget(identifier: String) {
        let locale = Locale(identifier: identifier)
        for meters in [0.0, 1.0, 217.4382, 535.0, 1250.0] {
            #expect(
                Self.elevation(meters, identifier)
                    == WidgetFormat.elevation(meters: meters, locale: locale),
                "\(identifier) disagreed about \(meters) m"
            )
        }
    }

    /// Never promoted to kilometres or miles: a 1,250 m summit is 1,250 m
    /// high, not "1.2 km" high, which is what `.road` and `.general` would
    /// both make of it — and what makes this the one length in the app that
    /// cannot simply use the distance formatter.
    @Test("a tall summit stays in the base unit", arguments: [
        "en_US", "en_GB", "de_DE", "ja_JP",
    ])
    func staysInTheBaseUnit(identifier: String) {
        let text = Self.elevation(8848, identifier)
        #expect(!text.contains("km"))
        #expect(!text.contains("mi"))
    }

    /// A depression below sea level is a real height, and so is sea level.
    @Test("heights at and below zero are still heights", arguments: [
        ("en_US", 0.0, "0 ft"),
        ("de_DE", 0.0, "0 m"),
        ("de_DE", -3.0, "-3 m"),
    ])
    func atOrBelowSeaLevel(identifier: String, meters: Double, expected: String) {
        #expect(Self.elevation(meters, identifier) == expected)
    }

    /// The same answer ``HikeFormat/duration(_:)`` gives, and for the same
    /// reason: a route carrying a height that isn't a number produces a
    /// non-finite total, and "∞ ft" on a stat tile reads as though something
    /// had been measured.
    @Test("a height that isn't a number reads as absent", arguments: [
        Double.infinity, -.infinity, .nan,
    ])
    func nonFiniteElevation(value: Double) {
        #expect(Self.elevation(value, "en_US") == "—")
        #expect(Self.elevation(value, "de_DE") == "—")
    }

    /// The spoken form is the same figure in the same unit, only spelled out —
    /// a US reader used to hear "535 meters at 0.4 miles" from the elevation
    /// chart's VoiceOver value.
    @Test("the spoken form keeps the region's unit", arguments: [
        ("en_US", 535.0, "1,755 feet"),
        ("de_DE", 535.0, "535 Meter"),
    ])
    func spoken(identifier: String, meters: Double, expected: String) {
        #expect(
            HikeFormat.spokenElevation(
                Measurement(value: meters, unit: .meters),
                locale: Locale(identifier: identifier)
            ) == expected
        )
    }

    /// The dash survives the wide spelling too.
    @Test("a spoken height that isn't a number reads as absent")
    func spokenNonFinite() {
        #expect(
            HikeFormat.spokenElevation(
                Measurement(value: .nan, unit: .meters),
                locale: Locale(identifier: "en_US")
            ) == "—"
        )
    }
}
