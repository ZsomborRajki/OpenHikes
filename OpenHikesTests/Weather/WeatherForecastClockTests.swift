//
//  WeatherForecastClockTests.swift
//  OpenHikesTests
//
//  A forecast's clock belongs to its place, while its spelling and hour cycle
//  belong to the reader. The sheet already named Tokyo's weekdays in Tokyo's
//  zone but drew and spoke its hours, sunrise, sunset and dusk in the device's
//  zone (#1157). These tests ask the actual view formatting policy about
//  remote places, midnight and both clock changes, with a stub geocoder.
//  No WeatherKit request, shared defaults or widget publication is involved.
//
//  The reader is pinned to New York, a zone none of these forecasts is in and
//  whose clocks change on other dates than Berlin's. Left to the device, the
//  Berlin cases passed with the forecast's zone ignored on any machine in
//  Central Europe, and the fallback case compared the device with itself.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@MainActor
@Suite("Weather forecast clock")
struct WeatherForecastClockTests {
    private func instant(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func clock(in identifier: String?) async throws -> ForecastClock {
        let zone = try identifier.map { try #require(TimeZone(identifier: $0)) }
        let manager = WeatherManager(placeNames: ClockPlaceNames(timeZone: zone), widgetPublisher: .inert)
        manager.focus(
            on: .place(CLLocationCoordinate2D(latitude: 35.7, longitude: 139.7), name: "Forecast"),
            willRequest: false
        )
        await manager.resolvePlace()
        #expect(manager.forecastTimeZone == zone)
        return ForecastClock(
            view: WeatherDetailView(weather: manager),
            reader: try #require(TimeZone(identifier: "America/New_York"))
        )
    }

    @Test("remote hours and daylight use their resolved zone", arguments: [
        ("Asia/Tokyo", "15", "15:00"),
        ("Pacific/Honolulu", "20", "20:00"),
    ])
    func remoteClock(identifier: String, hour: String, time: String) async throws {
        let clock = try await clock(in: identifier)
        let date = try instant("2026-10-23T06:00:00Z")

        #expect(clock.hour(date) == hour)
        #expect(clock.time(date) == time)
    }

    @Test("Tokyo's clock crosses midnight when Tokyo's day does")
    func midnightAbroad() async throws {
        let clock = try await clock(in: "Asia/Tokyo")
        let before = try instant("2026-10-23T14:50:00Z")
        let after = try instant("2026-10-23T15:20:00Z")

        #expect(clock.hour(before) == "23")
        #expect(clock.time(before) == "23:50")
        #expect(clock.hour(after) == "00")
        #expect(clock.time(after) == "0:20")
    }

    @Test("the forecast's spring transition skips an hour")
    func springClockChange() async throws {
        let clock = try await clock(in: "Europe/Berlin")
        let before = try instant("2026-03-29T00:30:00Z")
        let after = try instant("2026-03-29T01:30:00Z")

        #expect(clock.hour(before) == "01")
        #expect(clock.time(before) == "1:30")
        #expect(clock.hour(after) == "03")
        #expect(clock.time(after) == "3:30")
    }

    @Test("the forecast's autumn transition repeats an hour without shortening remaining light")
    func autumnClockChange() async throws {
        let clock = try await clock(in: "Europe/Berlin")
        let before = try instant("2026-10-25T00:30:00Z")
        let repeated = try instant("2026-10-25T01:30:00Z")
        let dusk = try instant("2026-10-25T02:30:00Z")

        #expect(clock.hour(before) == "02")
        #expect(clock.time(before) == "2:30")
        #expect(clock.hour(repeated) == "02")
        #expect(clock.time(repeated) == "2:30")
        #expect(clock.hour(dusk) == "03")
        let daylight = WeatherDaylight(sunrise: nil, sunset: nil, civilDusk: dusk)
        let remainingBefore = try #require(daylight.remainingLight(asOf: before))
        let remainingRepeated = try #require(daylight.remainingLight(asOf: repeated))
        #expect(remainingBefore.isApproximatelyEqual(to: 7200, absoluteTolerance: 0.001))
        #expect(remainingRepeated.isApproximatelyEqual(to: 3600, absoluteTolerance: 0.001))
    }

    @Test("the reader keeps their locale and hour-cycle override", arguments: [
        ("en_US", "3 PM", "3:30 PM"),
        ("de_DE", "15 Uhr", "15:30"),
        ("en_US-u-hc-h23", "15", "15:30"),
        ("de_DE-u-hc-h12", "3 PM", "3:30 PM"),
    ])
    func readersClock(identifier: String, hour: String, time: String) async throws {
        let clock = try await clock(in: "Asia/Tokyo")
        let date = try instant("2026-10-23T06:30:00Z")
        let locale = Locale(identifier: identifier)

        #expect(clock.hour(date, locale).replacingOccurrences(of: "\u{202F}", with: " ") == hour)
        #expect(clock.time(date, locale).replacingOccurrences(of: "\u{202F}", with: " ") == time)
    }

    @Test("a missing forecast zone keeps the reader's clock", arguments: [
        ("en_GB", "11", "11:20"),
        ("en_US", "11 AM", "11:20 AM"),
        ("de_DE", "11 Uhr", "11:20"),
    ])
    func unresolvedZone(identifier: String, hour: String, time: String) async throws {
        let clock = try await clock(in: nil)
        let date = try instant("2026-10-23T15:20:00Z")
        let locale = Locale(identifier: identifier)

        #expect(clock.hour(date, locale).replacingOccurrences(of: "\u{202F}", with: " ") == hour)
        #expect(clock.time(date, locale).replacingOccurrences(of: "\u{202F}", with: " ") == time)
    }
}

/// The sheet's clock policy, read by a reader whose zone is pinned.
@MainActor
private struct ForecastClock {
    static let british = Locale(identifier: "en_GB")

    let view: WeatherDetailView
    let reader: TimeZone

    func hour(_ date: Date, _ locale: Locale = Self.british) -> String {
        view.forecastHour(date, locale: locale, readerZone: reader)
    }

    func time(_ date: Date, _ locale: Locale = Self.british) -> String {
        view.forecastTime(date, locale: locale, readerZone: reader)
    }
}

@MainActor
private final class ClockPlaceNames: WeatherPlaceNaming {
    let timeZone: TimeZone?

    init(timeZone: TimeZone?) {
        self.timeZone = timeZone
    }

    func place(at coordinate: CLLocationCoordinate2D) -> WeatherPlaceDescription? {
        WeatherPlaceDescription(cityName: nil, timeZone: timeZone)
    }
}
