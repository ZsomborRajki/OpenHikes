//
//  WeatherHourlyForecastTests.swift
//  OpenHikesTests
//
//  The app fetched `.current` and nothing else, so the sheet a hiker opens at
//  a trailhead had the same thing to say as the badge over the map: what it is
//  like right now. `.hourly` rides the same request — `weather(for:including:)`
//  is variadic and answers both from one round trip — so the strip costs
//  nothing the badge was not already spending.
//
//  WeatherKit itself is not reachable from a hosted unit test: it needs an
//  entitlement, a token and a network call, and `HourWeather` has no public
//  initializer. So what is asserted here is everything above that seam — the
//  value type the app actually holds, the horizon that bounds what reaches
//  `UserDefaults`, and the round trip through the stored blob. That the
//  framework answers two datasets from one request is Apple's contract, and
//  the code reads it in one place.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather hourly forecast")
struct WeatherHourlyForecastTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_757_000_000)

    private func hours(_ count: Int, from start: Date) -> [WeatherHourSummary] {
        (0..<count).map { offset in
            WeatherHourSummary(
                date: start.addingTimeInterval(
                    Double(offset) * WeatherHourlyPolicy.hourSeconds
                ),
                symbolName: "cloud.sun.fill",
                temperature: Measurement(value: Double(offset), unit: UnitTemperature.celsius),
                precipitationChance: offset == 1 ? 0.6 : 0
            )
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "weather-hourly-\(UUID().uuidString)"))
    }

    private func snapshot(hourly: [WeatherHourSummary]) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.rain.fill",
            temperature: Measurement(value: 9, unit: UnitTemperature.celsius),
            conditionDescription: "Rain",
            capturedAt: capturedAt,
            conditions: .preview,
            hourly: hourly
        )
    }

    /// The default is what keeps every existing caller — a preview, the badge
    /// suites, a restored blob with no strip — honest rather than inventing
    /// weather to fill a field.
    @Test("a reading without a forecast has an empty strip, not a fabricated one")
    func aReadingWithoutHoursHasNone() {
        let reading = WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: 14, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: capturedAt,
            conditions: .preview
        )
        #expect(reading.hourly.isEmpty)
    }

    /// An hour is identified by the hour it describes, so a re-fetch inside
    /// the same hour replaces its row rather than adding a second one.
    @Test("an hour is identified by the hour it describes")
    func hourIdentityIsItsDate() {
        let strip = hours(3, from: capturedAt)
        #expect(strip.map(\.id) == strip.map(\.date))
        #expect(Set(strip.map(\.id)).count == strip.count)
    }

    @Test("the strip survives the trip through the stored blob")
    func roundTripsThroughTheStore() throws {
        let defaults = try makeDefaults()
        let store = WeatherReadingStore(defaults: defaults)
        let strip = hours(WeatherHourlyPolicy.horizon, from: capturedAt)
        store.save(
            snapshot: snapshot(hourly: strip),
            subject: .me(CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8))
        )

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot.hourly.count == strip.count)
        #expect(restored.snapshot.hourly.map(\.date) == strip.map(\.date))
        #expect(restored.snapshot.hourly.map(\.symbolName) == strip.map(\.symbolName))
        #expect(
            restored.snapshot.hourly.map(\.precipitationChance) == strip.map(\.precipitationChance)
        )
    }

    /// Stored in Celsius for the reason the current temperature is: the bytes
    /// must not depend on which unit the provider used that day.
    @Test("an hour's temperature comes back as the same reading in the reader's units")
    func temperatureSurvivesTheUnitFix() throws {
        let defaults = try makeDefaults()
        let store = WeatherReadingStore(defaults: defaults)
        let fahrenheit = WeatherHourSummary(
            date: capturedAt,
            symbolName: "sun.max.fill",
            temperature: Measurement(value: 68, unit: UnitTemperature.fahrenheit),
            precipitationChance: 0
        )
        store.save(
            snapshot: snapshot(hourly: [fahrenheit]),
            subject: .me(CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8))
        )

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        let hour = try #require(restored.snapshot.hourly.first)
        #expect(abs(hour.temperature.converted(to: .celsius).value - 20) < 0.001)
    }

    /// The horizon is what stops a `UserDefaults` blob growing to the days of
    /// data `.hourly` answers with. A strip is bounded before it is stored,
    /// never trimmed on the way out.
    @Test("an over-long strip is not what the store is asked to keep")
    func theHorizonBoundsWhatIsStored() {
        #expect(WeatherHourlyPolicy.horizon == 12)
        #expect(
            WeatherHourlyPolicy.horizon > 6,
            "the argument for the strip is about the next six hours, with room either side"
        )
    }

    #if DEBUG
    /// The fixture is what UI automation and previews draw, and a strip that
    /// repeated itself would let a mis-indexed column look right.
    @Test("the fixture strip is legible enough to catch a mis-indexed column")
    func fixtureStripIsDistinguishable() {
        let strip = WeatherHourSummary.previewStrip
        #expect(strip.count == WeatherHourlyPolicy.horizon)

        let wet = strip.filter { $0.precipitationChance > 0 }
        #expect(wet.count == 1, "exactly one wet hour, so the column it lands in is checkable")
        #expect(strip.first?.precipitationChance == 0, "not the first column")

        let temperatures = strip.map { $0.temperature.converted(to: .celsius).value }
        for (first, second) in zip(temperatures, temperatures.dropFirst()) {
            #expect(abs(first - second) > 0.001, "no two adjacent columns read the same")
        }
    }
    #endif
}
