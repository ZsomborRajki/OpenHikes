//
//  WeatherDailyForecastTests.swift
//  OpenHikesTests
//
//  `.daily` was in the request before anything read more than its first day:
//  ten days arrived on every fetch, ``WeatherDaylight`` took today's sun out
//  of them and the other nine were decoded and dropped. The week is that data,
//  kept — so this costs nothing on the network, and everything asserted here
//  is about what the app does with a response it was already receiving.
//
//  WeatherKit itself is not reachable from a hosted unit test — an
//  entitlement, a token, a network call, and `DayWeather` has no public
//  initializer — so the seam is the same one ``WeatherHourlyForecastTests``
//  works against: the value the app holds, the horizon that bounds what
//  reaches `UserDefaults`, and the round trip through the stored blob.
//
//  The one thing here that is not a mirror of the hourly suite is the last
//  test, and it is the interesting one: a blob written by the build that read
//  only the first day of `.daily` has no week in it, and must not restore as
//  *this place has no daily forecast*. The stored field is non-optional
//  precisely so that blob is discarded and re-fetched instead — the reset
//  policy ``WeatherReadingStore``'s header describes, rather than a third
//  state meaning "no rows" beside the empty array that already means it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Weather daily forecast")
struct WeatherDailyForecastTests {
    private let capturedAt = Date(timeIntervalSince1970: 1_757_000_000)
    private let anywhere = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.8)
    /// Twenty-four hours. A fixture may assume it; the mapping may not, which
    /// is why that one asks a `Calendar`.
    private let daySeconds: TimeInterval = 86_400

    private func days(_ count: Int, from start: Date) -> [WeatherDaySummary] {
        (0..<count).map { offset in
            WeatherDaySummary(
                date: start.addingTimeInterval(Double(offset) * daySeconds),
                symbolName: "cloud.sun.fill",
                highTemperature: Measurement(
                    value: Double(offset) + 10,
                    unit: UnitTemperature.celsius
                ),
                lowTemperature: Measurement(
                    value: Double(offset),
                    unit: UnitTemperature.celsius
                ),
                precipitationChance: offset == 1 ? 0.6 : 0
            )
        }
    }

    /// The same week, dated through a `Calendar` — see
    /// ``yesterdayIsDroppedOnTheWayToTheScreen()`` for why a flat day is not
    /// good enough where the assertion is about calendar days.
    private func calendarDays(_ count: Int, from start: Date) throws -> [WeatherDaySummary] {
        let calendar = Calendar.autoupdatingCurrent
        return try (0..<count).map { offset in
            let date = try #require(calendar.date(byAdding: .day, value: offset, to: start))
            return WeatherDaySummary(
                date: date,
                symbolName: "cloud.sun.fill",
                highTemperature: Measurement(
                    value: Double(offset) + 10,
                    unit: UnitTemperature.celsius
                ),
                lowTemperature: Measurement(value: Double(offset), unit: UnitTemperature.celsius),
                precipitationChance: 0
            )
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "weather-daily-\(UUID().uuidString)"))
    }

    private func snapshot(days: [WeatherDaySummary]) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.rain.fill",
            temperature: Measurement(value: 9, unit: UnitTemperature.celsius),
            conditionDescription: "Rain",
            capturedAt: capturedAt,
            conditions: .preview,
            days: days
        )
    }

    /// The default is what keeps every existing caller — a preview, the badge
    /// suites, a restored blob with no week — honest rather than inventing a
    /// forecast to fill a field.
    @Test("a reading without a week has an empty one, not a fabricated one")
    func aReadingWithoutDaysHasNoWeek() {
        let reading = WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: 14, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: capturedAt,
            conditions: .preview
        )
        #expect(reading.days.isEmpty)
    }

    /// A day is identified by the day it describes, so a re-fetch inside the
    /// same day replaces its row rather than adding a second one.
    @Test("a day is identified by the day it describes")
    func dayIdentityIsItsDate() {
        let week = days(WeatherDailyPolicy.horizon, from: capturedAt)
        #expect(week.map(\.id) == week.map(\.date))
        #expect(Set(week.map(\.id)).count == week.count)
    }

    @Test("the week survives the trip through the stored blob")
    func roundTripsThroughTheStore() throws {
        let defaults = try makeDefaults()
        let week = days(WeatherDailyPolicy.horizon, from: capturedAt)
        WeatherReadingStore(defaults: defaults)
            .save(snapshot: snapshot(days: week), subject: .me(anywhere))

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        let stored = restored.snapshot.days
        #expect(stored.map(\.date) == week.map(\.date))
        #expect(stored.map(\.symbolName) == week.map(\.symbolName))
        #expect(stored.map(\.precipitationChance) == week.map(\.precipitationChance))
    }

    /// A provider that genuinely had no daily data for the point stored an
    /// empty week, and that is what comes back — the one thing an empty array
    /// is allowed to mean.
    @Test("an empty week is stored as an empty week")
    func anEmptyWeekSurvivesAsEmpty() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults)
            .save(snapshot: snapshot(days: []), subject: .me(anywhere))

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot.days.isEmpty)
    }

    /// The reset policy, asserted on the blob a shipped build actually wrote.
    ///
    /// That build asked for `.daily` and kept only its first day, so its blob
    /// has no `days` key. It is discarded rather than restored as a week-less
    /// reading, because an empty week already means something else — see
    /// ``WeatherSnapshot/days``. The cost is one launch that draws no badge
    /// for the few seconds until WeatherKit answers.
    ///
    /// Written through the real encoder with the key removed, rather than by
    /// hand, so it is the shipped format being decoded and not a guess at it.
    @Test("a reading stored before the week existed is dropped, not patched")
    func aBlobWithNoWeekIsDiscarded() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults)
            .save(snapshot: snapshot(days: days(3, from: capturedAt)), subject: .me(anywhere))
        let written = try #require(defaults.data(forKey: SettingsKey.lastWeatherReading))
        var object = try #require(
            JSONSerialization.jsonObject(with: written) as? [String: Any]
        )
        #expect(object["days"] != nil, "the field being removed has to have been there")
        object.removeValue(forKey: "days")
        defaults.set(
            try JSONSerialization.data(withJSONObject: object),
            forKey: SettingsKey.lastWeatherReading
        )

        #expect(WeatherReadingStore(defaults: defaults).load() == nil)
    }

    /// Stored in Celsius for the reason the current temperature is: the bytes
    /// must not depend on which unit the provider used that day.
    @Test("a day's range comes back as the same reading in the reader's units")
    func temperaturesSurviveTheUnitFix() throws {
        let defaults = try makeDefaults()
        let fahrenheit = WeatherDaySummary(
            date: capturedAt,
            symbolName: "sun.max.fill",
            highTemperature: Measurement(value: 68, unit: UnitTemperature.fahrenheit),
            lowTemperature: Measurement(value: 50, unit: UnitTemperature.fahrenheit),
            precipitationChance: 0
        )
        WeatherReadingStore(defaults: defaults)
            .save(snapshot: snapshot(days: [fahrenheit]), subject: .me(anywhere))

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        let day = try #require(restored.snapshot.days.first)
        #expect(
            day.highTemperature.converted(to: .celsius).value.isApproximatelyEqual(to: 20, absoluteTolerance: 0.001)
        )
        #expect(day.lowTemperature.converted(to: .celsius).value.isApproximatelyEqual(to: 10, absoluteTolerance: 0.001))
    }

    /// The reading is filtered on the way *out* as well as on the way in,
    /// and this is the case that needs it: nothing in ``WeatherManager``
    /// expires, so a blob written last night is drawn this morning exactly as
    /// it was stored. Trimmed only at the fetch, its first row is yesterday.
    ///
    /// Built through a `Calendar` rather than through ``days(_:from:)``,
    /// which adds a flat 86,400 seconds: anchored to a real midnight, that
    /// helper puts two rows on one calendar day the morning the clocks go
    /// forward, and this test is about which calendar day a row falls on.
    @Test("a week stored yesterday no longer opens on yesterday")
    func yesterdayIsDroppedOnTheWayToTheScreen() throws {
        let calendar = Calendar.autoupdatingCurrent
        let yesterday = try #require(
            calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))
        )
        let week = try calendarDays(WeatherDailyPolicy.horizon, from: yesterday)

        let drawn = WeatherDaySummary.upcoming(in: week, asOf: .now)
        #expect(drawn.count == week.count - 1)
        #expect(
            !drawn.contains { calendar.isDate($0.date, inSameDayAs: yesterday) },
            "a day that has ended is not a day to walk on"
        )
        let first = try #require(drawn.first)
        #expect(
            calendar.isDateInToday(first.date),
            "the strip opens on the day in progress, which the sheet names Today"
        )
    }

    /// The day in progress is the one the strip exists to keep, so the filter
    /// runs to the end of it rather than to its start.
    @Test("the day in progress survives until it actually ends")
    func todaySurvivesUntilMidnight() throws {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: today))
        let lateTonight = try #require(calendar.date(byAdding: .minute, value: -1, to: midnight))

        let week = try calendarDays(2, from: today)
        #expect(
            WeatherDaySummary.upcoming(in: week, asOf: lateTonight).count == 2,
            "a minute before midnight, today has not gone yet"
        )
        #expect(
            WeatherDaySummary.upcoming(in: week, asOf: midnight).count == 1,
            "and at midnight it has"
        )
    }

    /// The horizon is the decision the issue was filed about: WeatherKit's ten
    /// days are not ten days of useful forecast, and a week is the unit the
    /// question is asked in. It is also what stops the `UserDefaults` blob
    /// carrying a day nobody will read.
    @Test("the horizon is a week, not what the provider happens to send")
    func theHorizonIsAWeek() {
        #expect(WeatherDailyPolicy.horizon == 7)
        #expect(
            WeatherDailyPolicy.horizon < 10,
            "the provider's ten days are not ten days of forecast worth drawing"
        )
        #expect(
            WeatherDailyPolicy.horizon >= 7,
            "the question is which day this week, so the strip has to reach the weekend"
        )
    }

    #if DEBUG
    /// The fixture is what UI automation and previews draw, and a week that
    /// repeated itself would let a mis-indexed row look right.
    @Test("the fixture week is legible enough to catch a mis-indexed row")
    func fixtureWeekIsDistinguishable() {
        let week = WeatherDaySummary.previewWeek
        #expect(week.count == WeatherDailyPolicy.horizon)

        let wet = week.filter { $0.precipitationChance > 0 }
        #expect(wet.count == 1, "exactly one wet day, so the row it lands in is checkable")
        #expect(week.first?.precipitationChance == 0, "not the first row")

        let highs = week.map { $0.highTemperature.converted(to: .celsius).value }
        for (first, second) in zip(highs, highs.dropFirst()) {
            #expect(abs(first - second) > 0.001, "no two adjacent rows read the same")
        }
        for day in week {
            #expect(
                day.lowTemperature.converted(to: .celsius).value
                    < day.highTemperature.converted(to: .celsius).value,
                "a low below its high, so a row drawing them the wrong way round shows"
            )
        }
    }

    /// The fixture starts today, because the mapping keeps the day in progress
    /// and the sheet's first row says "Today" for it.
    @Test("the fixture week begins with the day in progress")
    func fixtureWeekBeginsToday() throws {
        let first = try #require(WeatherDaySummary.previewWeek.first)
        #expect(Calendar.autoupdatingCurrent.isDateInToday(first.date))
    }
    #endif
}
