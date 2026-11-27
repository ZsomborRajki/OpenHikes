//
//  WeatherTodayTests.swift
//  OpenHikesTests
//
//  The weather sheet's head gives today's high and low, and its days panel
//  names a row *Today* and marks the reading's temperature on its bar. Both
//  read ``WeatherToday``, which is what keeps them on one day after
//  midnight, while the newest reading is still yesterday's.
//
//  Built through a `Calendar` in a fixed zone, because the assertions are
//  about which day an instant falls in, and a flat 86,400 seconds is not a
//  day the morning the clocks change.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather today")
struct WeatherTodayTests {
    private static let zone = "Europe/Vienna"

    private func calendar() throws -> Calendar {
        WeatherForecastDay.calendar(in: try #require(TimeZone(identifier: Self.zone)))
    }

    /// A week from 20 November 2026, each day dated at midnight in
    /// ``zone``, each high a degree warmer than the day before so a row
    /// read from the wrong day shows it.
    private func week(in calendar: Calendar) throws -> [WeatherDaySummary] {
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20)))
        return try (0..<WeatherDailyPolicy.horizon).map { offset in
            WeatherDaySummary(
                date: try #require(calendar.date(byAdding: .day, value: offset, to: start)),
                symbolName: "cloud.sun.fill",
                highTemperature: Measurement(value: Double(10 + offset), unit: UnitTemperature.celsius),
                lowTemperature: Measurement(value: Double(offset), unit: UnitTemperature.celsius),
                precipitationChance: 0
            )
        }
    }

    /// `hour`:`minute` on the `day`th day of ``week(in:)``.
    private func time(day: Int, hour: Int, minute: Int, in calendar: Calendar) throws -> Date {
        try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 20 + day, hour: hour, minute: minute))
        )
    }

    @Test("a reading taken today is today's, and marked on its bar")
    func readingTakenToday() throws {
        let calendar = try calendar()
        let week = try week(in: calendar)
        let now = try time(day: 2, hour: 11, minute: 5, in: calendar)
        let takenAt = try time(day: 2, hour: 10, minute: 55, in: calendar)

        let today = try #require(
            WeatherToday(week: week, asOf: now, readingTakenAt: takenAt, calendar: calendar)
        )
        #expect(today.day == week[2])
        #expect(today.holdsReading)
    }

    /// The case the type exists for. The days panel has moved on to the new
    /// day; the head moves with it, and the reading, which is still
    /// yesterday's, is not set on the new day's bar.
    @Test("after midnight, yesterday's reading is not today's")
    func readingFromYesterday() throws {
        let calendar = try calendar()
        let week = try week(in: calendar)
        let takenAt = try time(day: 0, hour: 23, minute: 50, in: calendar)
        let now = try time(day: 1, hour: 0, minute: 10, in: calendar)
        let drawn = WeatherDaySummary.upcoming(in: week, asOf: now, calendar: calendar)

        let today = try #require(
            WeatherToday(week: drawn, asOf: now, readingTakenAt: takenAt, calendar: calendar)
        )
        #expect(today.day == week[1], "the head gives the day the Today row gives")
        #expect(!today.holdsReading, "yesterday's 23:50 is not where today stands")
    }

    /// The sheet hands over the week it has already trimmed, but the answer
    /// does not lean on that: today is the day the moment falls in.
    @Test("today is the day the moment falls in, trimmed week or not")
    func untrimmedWeek() throws {
        let calendar = try calendar()
        let week = try week(in: calendar)
        let takenAt = try time(day: 0, hour: 23, minute: 50, in: calendar)
        let now = try time(day: 1, hour: 0, minute: 10, in: calendar)

        let today = try #require(
            WeatherToday(week: week, asOf: now, readingTakenAt: takenAt, calendar: calendar)
        )
        #expect(today.day == week[1])
        #expect(!today.holdsReading)
    }

    /// A day lasts until the next one starts, and not a second longer.
    @Test("a reading taken in the last minute of the day is that day's")
    func lastMinute() throws {
        let calendar = try calendar()
        let week = try week(in: calendar)
        let lastMinute = try time(day: 3, hour: 23, minute: 59, in: calendar)
        let midnight = try time(day: 4, hour: 0, minute: 0, in: calendar)

        let before = try #require(
            WeatherToday(week: week, asOf: lastMinute, readingTakenAt: lastMinute, calendar: calendar)
        )
        #expect(before.day == week[3])
        #expect(before.holdsReading)

        let after = try #require(
            WeatherToday(week: week, asOf: midnight, readingTakenAt: lastMinute, calendar: calendar)
        )
        #expect(after.day == week[4])
        #expect(!after.holdsReading)
    }

    /// A week that has not begun yet, or one that has ended, has no today:
    /// the head then gives no range rather than one from another day.
    @Test("no day in progress, no today")
    func noDayInProgress() throws {
        let calendar = try calendar()
        let week = try week(in: calendar)
        let dayBefore = try time(day: -1, hour: 12, minute: 0, in: calendar)
        let weekAfter = try time(day: WeatherDailyPolicy.horizon, hour: 12, minute: 0, in: calendar)

        #expect(WeatherToday(week: week, asOf: dayBefore, readingTakenAt: dayBefore, calendar: calendar) == nil)
        #expect(WeatherToday(week: week, asOf: weekAfter, readingTakenAt: weekAfter, calendar: calendar) == nil)
        #expect(WeatherToday(week: [], asOf: dayBefore, readingTakenAt: dayBefore, calendar: calendar) == nil)
    }
}
