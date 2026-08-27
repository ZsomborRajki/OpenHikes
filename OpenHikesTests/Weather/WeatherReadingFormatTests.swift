//
//  WeatherReadingFormatTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Testing

/// The badge and its VoiceOver value are one quantity spelled two ways, and
/// this is where that is held to.
///
/// Every assertion pins an explicit `Locale`. The device's own locale is not a
/// fact a test may depend on — and the bug these exist for was invisible in
/// `en_GB`, where a Celsius reading and a Celsius display happen to agree.
@Suite("Weather reading format")
struct WeatherReadingFormatTests {
    private let reading = WeatherSnapshot(
        symbolName: "cloud.sun.fill",
        temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
        conditionDescription: "Partly Cloudy",
        capturedAt: Date(timeIntervalSinceReferenceDate: 1_000_000)
    )

    @Test("a Celsius reading is converted to the locale's weather unit")
    func convertsToLocaleUnit() {
        // 12 °C is 53.6 °F, which rounds to 54. The badge used to draw the
        // Celsius number under a bare degree sign, so a reader in `en_US` was
        // shown `12°` — twelve degrees Fahrenheit, or −11 °C.
        #expect(reading.formattedTemperature(locale: Locale(identifier: "en_US")) == "54°")
        #expect(reading.formattedTemperature(locale: Locale(identifier: "en_GB")) == "12°C")
        #expect(reading.formattedTemperature(locale: Locale(identifier: "de_DE")) == "12 °C")
    }

    @Test("the spoken value is the same quantity, spelled out")
    func spokenValueMatchesTheDrawnOne() {
        #expect(reading.spokenTemperature(locale: Locale(identifier: "en_US")) == "54 degrees Fahrenheit")
        #expect(reading.spokenTemperature(locale: Locale(identifier: "en_GB")) == "12 degrees Celsius")
        #expect(reading.spokenTemperature(locale: Locale(identifier: "de_DE")) == "12 Grad Celsius")
    }

    /// The regression itself: whatever the two renderings say, they have to be
    /// saying it about the same number.
    @Test(
        "the drawn number is the spoken number in every locale",
        arguments: ["en_US", "en_GB", "de_DE", "fr_FR", "ja_JP"]
    )
    func drawnAndSpokenAgree(localeID: String) {
        let locale = Locale(identifier: localeID)
        let drawnDigits = digits(in: reading.formattedTemperature(locale: locale))
        let spokenDigits = digits(in: reading.spokenTemperature(locale: locale))

        #expect(!drawnDigits.isEmpty)
        #expect(drawnDigits == spokenDigits)
    }

    /// WeatherKit reports to full `Double` precision; left at the format
    /// style's default that arrives in the badge as `54.22208°`.
    @Test("a full-precision reading is rounded to whole degrees")
    func roundsToWholeDegrees() {
        let precise = WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: 12.3456, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: .now
        )

        #expect(precise.formattedTemperature(locale: Locale(identifier: "en_US")) == "54°")
        #expect(precise.formattedTemperature(locale: Locale(identifier: "en_GB")) == "12°C")
    }

    @Test("a sub-zero reading keeps its sign")
    func negativeReading() {
        let freezing = WeatherSnapshot(
            symbolName: "snowflake",
            temperature: Measurement(value: -6, unit: UnitTemperature.celsius),
            conditionDescription: "Snow",
            capturedAt: .now
        )

        #expect(freezing.formattedTemperature(locale: Locale(identifier: "en_GB")) == "-6°C")
        #expect(freezing.formattedTemperature(locale: Locale(identifier: "en_US")) == "21°")
    }

    /// Splitting a formatted measurement into just its digits, so the drawn
    /// and spoken forms can be compared without depending on how a locale
    /// spells the unit.
    private func digits(in formatted: String) -> String {
        formatted.filter(\.isNumber)
    }
}
