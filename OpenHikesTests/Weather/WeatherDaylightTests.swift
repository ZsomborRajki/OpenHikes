//
//  WeatherDaylightTests.swift
//  OpenHikesTests
//
//  The daylight half of a reading, and the places where the honest answer is
//  "there isn't one".
//
//  `WeatherDaylight.forDay(of:in:)` is not reachable from here — building a
//  `Forecast<DayWeather>` needs WeatherKit to have answered — so what this
//  covers is the value itself and the round trip through
//  ``WeatherReadingStore``, which is where a stored reading is either kept or
//  thrown away. That split is the same one the rest of the weather suites
//  make, and for the same reason: everything worth asserting sits on this
//  side of the network.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather daylight")
struct WeatherDaylightTests {
    private static let noon = Date(timeIntervalSince1970: 1_780_000_000)
    private static let anHour: TimeInterval = 3600

    private static func daylight(
        sunset: Date? = nil,
        civilDusk: Date? = nil
    ) -> WeatherDaylight {
        WeatherDaylight(sunrise: nil, sunset: sunset, civilDusk: civilDusk)
    }

    // MARK: Where there is no sun

    /// Above the Arctic Circle in June there is no sunset, and in December no
    /// sunrise. Those are hiking destinations rather than edge cases — see
    /// ``WeatherDaylight``.
    @Test("a day with no sunrise, sunset or dusk has no daylight to draw")
    func polarDayHasNothingToDraw() {
        #expect(!Self.daylight().hasDaylightTimes)
    }

    @Test("any one of the three is enough to draw the section")
    func oneTimeIsEnough() {
        #expect(Self.daylight(sunset: Self.noon).hasDaylightTimes)
        #expect(Self.daylight(civilDusk: Self.noon).hasDaylightTimes)
        #expect(
            WeatherDaylight(sunrise: Self.noon, sunset: nil, civilDusk: nil)
                .hasDaylightTimes
        )
    }

    /// The high and low are a statement about the day rather than about the
    /// light, so a reading carrying only those has nothing for this section.
    @Test("temperatures alone are not daylight")
    func temperaturesAreNotDaylight() {
        let onlyRange = WeatherDaylight(
            highTemperature: Measurement(value: 16, unit: UnitTemperature.celsius),
            lowTemperature: Measurement(value: 4, unit: UnitTemperature.celsius)
        )

        #expect(!onlyRange.hasDaylightTimes)
    }

    // MARK: How much light is left

    @Test("light remaining counts towards civil dusk, not sunset")
    func countsTowardsDusk() throws {
        let daylight = Self.daylight(
            sunset: Self.noon.addingTimeInterval(Self.anHour),
            civilDusk: Self.noon.addingTimeInterval(2 * Self.anHour)
        )

        let remaining = try #require(daylight.remainingLight(asOf: Self.noon))

        #expect(remaining == 2 * Self.anHour, "dusk is what ends the walk")
    }

    /// "−40 minutes of daylight" is not a thing to put on a screen. The row
    /// disappears and the times themselves are what remain.
    @Test("a dusk already past reports nothing rather than a negative")
    func refusesANegativeInterval() {
        let daylight = Self.daylight(civilDusk: Self.noon.addingTimeInterval(-Self.anHour))

        #expect(daylight.remainingLight(asOf: Self.noon) == nil)
    }

    @Test("a day with no dusk has no interval to report")
    func noDuskNoInterval() {
        #expect(Self.daylight(sunset: Self.noon).remainingLight(asOf: Self.noon) == nil)
    }

    // MARK: Surviving a relaunch

    /// The asymmetry this file exists to pin. `conditions` and `hourly` are
    /// non-optional in the stored payload so a blob written before they
    /// existed fails to decode and is refetched — a reading without them is
    /// wrong. A reading without daylight is merely older, so it survives and
    /// gains the section on the next fetch.
    @Test("a stored reading keeps its daylight across a relaunch")
    func daylightSurvivesTheStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "daylight-\(UUID().uuidString)"))
        let store = WeatherReadingStore(defaults: defaults)
        let daylight = WeatherDaylight(
            sunrise: Self.noon,
            sunset: Self.noon.addingTimeInterval(Self.anHour),
            civilDusk: Self.noon.addingTimeInterval(2 * Self.anHour),
            highTemperature: Measurement(value: 16, unit: UnitTemperature.celsius),
            lowTemperature: Measurement(value: 4, unit: UnitTemperature.celsius)
        )
        let snapshot = WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: Self.noon,
            conditions: .preview,
            daylight: daylight
        )

        store.save(snapshot: snapshot, subject: .uiTestFixtureSubject)
        let restored = try #require(store.load())

        #expect(restored.snapshot.daylight == daylight)
    }

    /// A reading that never carried daylight still loads. Written through the
    /// same encoder rather than by hand, so this asserts the optional column
    /// rather than a fixture's idea of one.
    @Test("a reading with no daylight still restores")
    func anAbsentDaylightStillRestores() throws {
        let defaults = try #require(UserDefaults(suiteName: "daylight-\(UUID().uuidString)"))
        let store = WeatherReadingStore(defaults: defaults)
        let snapshot = WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: Self.noon,
            conditions: .preview
        )

        store.save(snapshot: snapshot, subject: .uiTestFixtureSubject)
        let restored = try #require(store.load())

        #expect(restored.snapshot.daylight == nil)
        #expect(restored.snapshot.conditionDescription == "Partly Cloudy")
    }
}
