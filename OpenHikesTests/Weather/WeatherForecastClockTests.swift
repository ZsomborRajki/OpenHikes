//
//  WeatherForecastClockTests.swift
//  OpenHikesTests
//
//  A forecast's clock belongs to its place, while its spelling and hour cycle
//  belong to the reader. The sheet already named Tokyo's weekdays in Tokyo's
//  zone but drew and spoke its hours, sunrise, sunset and dusk in the device's
//  zone (#1157). These tests ask the actual view formatting policy about
//  remote places, midnight and both clock changes, with an inert geocoder.
//  No WeatherKit request, shared defaults or widget publication is involved.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@MainActor
@Suite("Weather forecast clock")
struct WeatherForecastClockTests {
    private static let british = Locale(identifier: "en_GB")

    private func instant(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func view(in identifier: String?) async throws -> WeatherDetailView {
        let zone = try identifier.map { try #require(TimeZone(identifier: $0)) }
        let manager = WeatherManager(placeNames: ClockPlaceNames(timeZone: zone), widgetPublisher: .inert)
        manager.focus(
            on: .place(CLLocationCoordinate2D(latitude: 35.7, longitude: 139.7), name: "Forecast"),
            willRequest: false
        )
        await manager.resolvePlace()
        #expect(manager.forecastTimeZone == zone)
        return WeatherDetailView(weather: manager)
    }

    @Test("remote hours and daylight use their resolved zone", arguments: [
        ("Asia/Tokyo", "15", "15:00"),
        ("Pacific/Honolulu", "20", "20:00"),
    ])
    func remoteClock(identifier: String, hour: String, time: String) async throws {
        let view = try await view(in: identifier)
        let date = try instant("2026-10-23T06:00:00Z")

        #expect(view.forecastHour(date, locale: Self.british) == hour)
        #expect(view.forecastTime(date, locale: Self.british) == time)
    }

    @Test("Tokyo's clock crosses midnight when Tokyo's day does")
    func midnightAbroad() async throws {
        let view = try await view(in: "Asia/Tokyo")
        let before = try instant("2026-10-23T14:50:00Z")
        let after = try instant("2026-10-23T15:20:00Z")

        #expect(view.forecastHour(before, locale: Self.british) == "23")
        #expect(view.forecastTime(before, locale: Self.british) == "23:50")
        #expect(view.forecastHour(after, locale: Self.british) == "00")
        #expect(view.forecastTime(after, locale: Self.british) == "0:20")
    }

    @Test("the forecast's spring transition skips an hour")
    func springClockChange() async throws {
        let view = try await view(in: "Europe/Berlin")
        let before = try instant("2026-03-29T00:30:00Z")
        let after = try instant("2026-03-29T01:30:00Z")

        #expect(view.forecastHour(before, locale: Self.british) == "01")
        #expect(view.forecastTime(before, locale: Self.british) == "1:30")
        #expect(view.forecastHour(after, locale: Self.british) == "03")
        #expect(view.forecastTime(after, locale: Self.british) == "3:30")
    }

    @Test("the forecast's autumn transition repeats an hour without shortening remaining light")
    func autumnClockChange() async throws {
        let view = try await view(in: "Europe/Berlin")
        let before = try instant("2026-10-25T00:30:00Z")
        let repeated = try instant("2026-10-25T01:30:00Z")
        let dusk = try instant("2026-10-25T02:30:00Z")

        #expect(view.forecastHour(before, locale: Self.british) == "02")
        #expect(view.forecastTime(before, locale: Self.british) == "2:30")
        #expect(view.forecastHour(repeated, locale: Self.british) == "02")
        #expect(view.forecastTime(repeated, locale: Self.british) == "2:30")
        #expect(view.forecastHour(dusk, locale: Self.british) == "03")
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
        let view = try await view(in: "Asia/Tokyo")
        let date = try instant("2026-10-23T06:30:00Z")
        let locale = Locale(identifier: identifier)

        #expect(view.forecastHour(date, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ") == hour)
        #expect(view.forecastTime(date, locale: locale).replacingOccurrences(of: "\u{202F}", with: " ") == time)
    }

    @Test("a missing forecast zone keeps the device clock", arguments: ["en_GB", "en_US", "de_DE"])
    func unresolvedZone(identifier: String) async throws {
        let view = try await view(in: nil)
        let date = try instant("2026-10-23T15:20:00Z")
        let locale = Locale(identifier: identifier)

        #expect(view.forecastHour(date, locale: locale) == date.formatted(.dateTime.locale(locale).hour()))
        #expect(view.forecastTime(date, locale: locale) == date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        ))
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
