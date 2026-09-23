//
//  SharedWeatherReadingTests.swift
//  OpenHikesSharedTests
//
//  The temperature the app hands the widget. It is a four-field payload and
//  almost all of it is policy: what the unit on the wire is, when the number
//  stops being worth drawing, and which of the two spellings each reader gets.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Shared weather reading")
struct SharedWeatherReadingTests {
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)
    private static let celsius = Locale(identifier: "de_DE")
    private static let fahrenheit = Locale(identifier: "en_US")

    private static func reading(
        celsius temperature: Double = 12.3456,
        ageSeconds: TimeInterval = 0
    ) -> SharedWeatherReading? {
        SharedWeatherReading(
            temperatureCelsius: temperature,
            capturedAt: now.addingTimeInterval(-ageSeconds)
        )
    }

    // MARK: Attribution

    /// The glyph first and the word after, as Apple writes the mark — the
    /// one spelling of it both the widget and the sheet draw.
    @Test("the attribution mark is the Apple glyph and Weather")
    func attributionMark() {
        #expect(SharedWeatherReading.attributionMark == "\u{F8FF} Weather")
    }

    // MARK: Refusing what cannot be drawn

    /// `JSONEncoder` refuses a non-finite `Double`, so a reading built from
    /// one would never reach disk — the write would be a silent no-op rather
    /// than a value refused where it came from.
    @Test("a non-finite temperature is refused", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteIsRefused(temperature: Double) {
        #expect(SharedWeatherReading(temperatureCelsius: temperature, capturedAt: Self.now) == nil)
    }

    @Test("a reading survives the App Group round trip")
    func codableRoundTrip() throws {
        let reading = try #require(Self.reading())
        let decoded = try JSONDecoder().decode(
            SharedWeatherReading.self,
            from: JSONEncoder().encode(reading)
        )
        #expect(decoded == reading)
    }

    // MARK: Age

    /// Clamped at zero, so a provider clock a second ahead of the device's
    /// does not describe a reading from the future.
    @Test("a reading from the future is not negatively old")
    func futureReadingIsNotNegativelyOld() throws {
        let ahead = try #require(Self.reading(ageSeconds: -30))
        #expect(ahead.age(asOf: Self.now) == 0)
        #expect(!ahead.isExpired(asOf: Self.now))
    }

    /// The boundary is inclusive, and `expiresAt` names the same instant —
    /// the timeline schedules its wake-up from one and the renderer drops the
    /// reading by the other, so the two must not disagree by a second.
    @Test("expiry and the age test name the same instant")
    func expiryAgreesWithTheAgeTest() throws {
        let reading = try #require(Self.reading(ageSeconds: 0))
        let expiry = reading.expiresAt

        #expect(expiry == Self.now.addingTimeInterval(SharedWeatherReading.maximumAge))
        #expect(!reading.isExpired(asOf: expiry.addingTimeInterval(-1)))
        #expect(reading.isExpired(asOf: expiry))
    }

    // MARK: How it is written

    /// The widget's spelling is the shortest the locale accepts, which is a
    /// bare `54°` where the unit is unambiguous and `12 °C` where it is not —
    /// the same call the app's badge makes, so the home screen and the app
    /// cannot round one quantity two ways.
    @Test("the drawn form is the locale's narrowest spelling")
    func drawnFormIsNarrow() throws {
        let reading = try #require(Self.reading())

        #expect(
            reading.formatted(locale: Self.fahrenheit)
                == WidgetFormat.temperature(celsius: 12.3456, width: .narrow, locale: Self.fahrenheit)
        )
        #expect(reading.formatted(locale: Self.celsius).contains("12"))
        #expect(reading.formatted(locale: Self.fahrenheit).contains("54"))
    }

    /// Whole degrees, not every digit the provider sent through the
    /// conversion: 12.3456 °C is `54.22208°` unrounded, in a corner laid out
    /// for three characters.
    @Test("the temperature is rounded to whole degrees")
    func temperatureIsRounded() throws {
        let reading = try #require(Self.reading())
        #expect(!reading.formatted(locale: Self.fahrenheit).contains("."))
        #expect(!reading.formatted(locale: Self.celsius).contains(","))
    }

    /// A bare `54°` is not spoken as a temperature, so VoiceOver gets the
    /// quantity with its unit spelled out — and the *same* quantity, which is
    /// the mistake `WeatherReadingFormat`'s header exists to describe.
    @Test("the spoken form names the unit and keeps the number")
    func spokenFormNamesTheUnit() throws {
        let reading = try #require(Self.reading())
        let spoken = reading.spoken(locale: Self.fahrenheit)

        #expect(spoken.localizedCaseInsensitiveContains("fahrenheit"))
        #expect(spoken.contains("54"))
        #expect(reading.spoken(locale: Self.celsius).localizedCaseInsensitiveContains("celsius"))
    }
}
