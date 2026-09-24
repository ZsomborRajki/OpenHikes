//
//  SpeedFormatTests.swift
//  OpenHikesTests
//
//  Speed is a regional unit, and this is what says so.
//
//  The bug these exist for was invisible from a European desk: the stats grid
//  drew "3.1 mi" beside "5.0 km/h" for a reader in the United States, because
//  distance asked the region what it wanted and speed did not. Nothing here
//  reads `Locale.current` — an assertion that takes the machine's own region
//  as its input agrees with whatever the machine is set to, which is exactly
//  how the original bug survived a green suite.
//

import Foundation
@testable import OpenHikesData
import OpenHikesShared
import Testing

@Suite("Speed formatting")
struct SpeedFormatTests {
    private static func speed(_ metersPerSecond: Double, _ identifier: String) -> String {
        HikeFormat.speed(
            Measurement(value: metersPerSecond, unit: .metersPerSecond),
            locale: Locale(identifier: identifier)
        )
    }

    /// Pinned as whole strings rather than as "contains mph", so that a change
    /// to the unit, the rounding or the separator all have to be argued for
    /// rather than discovered.
    @Test("a US reader is given miles per hour", arguments: [
        (10.0, "22.4 mph"),
        (1.0, "2.2 mph"),
        (1.3888888, "3.1 mph"),
    ])
    func americanEnglish(metersPerSecond: Double, expected: String) {
        #expect(Self.speed(metersPerSecond, "en_US") == expected)
    }

    /// The UK measures road distance in miles and road speed in miles per
    /// hour, whatever it does with the weather — so it belongs with the US
    /// here and not with the metric list.
    @Test("a UK reader is given miles per hour too", arguments: [
        (10.0, "22.4 mph"),
        (1.3888888, "3.1 mph"),
    ])
    func britishEnglish(metersPerSecond: Double, expected: String) {
        #expect(Self.speed(metersPerSecond, "en_GB") == expected)
    }

    /// Both halves of a metric rendering: the unit *and* the separator, which
    /// is a comma here and a point in Japanese despite both being metric.
    @Test("a metric reader is given kilometres per hour", arguments: [
        ("de_DE", 10.0, "36,0 km/h"),
        ("de_DE", 1.0, "3,6 km/h"),
        ("de_DE", 1.3888888, "5,0 km/h"),
        ("ja_JP", 10.0, "36.0 km/h"),
        ("ja_JP", 1.3888888, "5.0 km/h"),
    ])
    func metricRegions(identifier: String, metersPerSecond: Double, expected: String) {
        #expect(Self.speed(metersPerSecond, identifier) == expected)
    }

    /// The invariant the bug actually broke. Whether a region wants miles is
    /// not something this suite should decide — it asks the same question the
    /// distance row asks, and requires the two answers to match. A future
    /// change to either row that leaves them disagreeing fails here.
    @Test(
        "speed follows the same system the distance row does",
        arguments: ["en_US", "en_GB", "de_DE", "ja_JP", "en_LR", "my_MM"]
    )
    func agreesWithTheDistanceRow(identifier: String) {
        let locale = Locale(identifier: identifier)
        let distance = Measurement(value: 5000, unit: UnitLength.meters)
            .formatted(
                .measurement(width: .abbreviated, usage: .road).locale(locale)
            )
        let speed = Self.speed(1.3888888, identifier)

        #expect(
            distance.contains("mi") == speed.contains("mph"),
            "\(identifier) drew \"\(distance)\" beside \"\(speed)\""
        )
    }

    /// A locale change must not smuggle in a precision change. Without an
    /// explicit number style the measurement rounds to whole units, and
    /// "4 km/h" cannot tell a stroll from a march.
    @Test("one decimal survives the conversion", arguments: [
        "en_US", "en_GB", "de_DE", "ja_JP",
    ])
    func keepsOneDecimal(identifier: String) throws {
        let text = Self.speed(1.3888888, identifier)
        let separator = try #require(Locale(identifier: identifier).decimalSeparator)
        let digits = try #require(text.split(separator: " ").first)
        let fraction = digits.components(separatedBy: separator).dropFirst().first

        #expect(fraction == "0" || fraction == "1", "expected one fraction digit in \"\(text)\"")
    }

    /// The same answer ``HikeFormat/length(_:)`` gives, and for the same
    /// reason: an average over a zero duration is an infinity, and "∞ mph"
    /// on a stat tile reads as though something had been measured.
    @Test("a speed that isn't a number reads as absent", arguments: [
        Double.infinity, -.infinity, .nan,
    ])
    func nonFiniteSpeed(value: Double) {
        #expect(Self.speed(value, "en_US") == "—")
        #expect(Self.speed(value, "de_DE") == "—")
    }

    /// The visible half of the bug this pair was filed for: two surfaces
    /// describing the same walk in two different units. `ElevationFormatTests`
    /// has had this assertion since the height rows were brought together;
    /// speed had none, which is how the widget kept converting by measurement
    /// system for as long as it did.
    ///
    /// The four agreeing locales could never have failed it. `en_LR` and
    /// `my_MM` are the two cheapest that can.
    @Test(
        "the app and the widget agree about the same pace",
        arguments: ["en_US", "en_GB", "de_DE", "ja_JP", "en_LR", "my_MM"]
    )
    func agreesWithTheWidget(identifier: String) {
        let locale = Locale(identifier: identifier)
        for metersPerSecond in [0.5, 1.0, 1.3888888, 2.5, 10.0] {
            #expect(
                Self.speed(metersPerSecond, identifier)
                    == WidgetFormat.speed(
                        metersPerSecond: metersPerSecond,
                        locale: locale
                    ),
                "\(identifier) disagreed about \(metersPerSecond) m/s"
            )
        }
    }

    /// The region the divergence was measured in, pinned as whole strings.
    /// Myanmar is `uksystem` and signs its roads in kilometres, so a hiker in
    /// Yangon reads km/h — on both surfaces, now.
    @Test("a region with imperial units and metric roads is given km/h", arguments: [
        ("en_LR", 1.3888888, "5.0 km/h"),
        ("my_MM", 1.3888888, "၅.၀ km/h"),
    ])
    func imperialSystemMetricRoads(identifier: String, metersPerSecond: Double, expected: String) {
        #expect(Locale(identifier: identifier).measurementSystem != .metric)
        #expect(Self.speed(metersPerSecond, identifier) == expected)
    }
}
