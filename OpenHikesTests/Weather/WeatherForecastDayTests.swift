//
//  WeatherForecastDayTests.swift
//  OpenHikesTests
//
//  Which forecast day an instant falls in, when the forecast is somewhere
//  else.
//
//  `DayWeather` is dated at midnight in the forecast's zone, and WeatherKit
//  does not say which zone that is. The daylight section, the walk's finish
//  estimate and the week's *Today* row all used to bucket those starts into
//  calendar days in the *reader's* zone, which read Tokyo from Berlin a day
//  late (#934). What is pinned here is the rule that replaced it — a day runs
//  from its start to the next day's start — against the zones that broke the
//  old one: a forecast ahead of the reader, one behind, one sixteen hours
//  away, and a day that is twenty-five hours long.
//
//  The starts are plain `Date`s built through a `Calendar` in the forecast's
//  zone, which is exactly what `.daily` hands over; `DayWeather` itself has no
//  public initializer, and nothing asserted here needs one.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Weather forecast day")
struct WeatherForecastDayTests {
    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    private func gregorian(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try zone(identifier)
        return calendar
    }

    private func instant(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    /// Midnight of `count` consecutive days in `identifier`'s zone, starting
    /// on the day `from` falls on there — the shape `.daily` arrives in.
    private func midnights(_ count: Int, in identifier: String, from date: Date) throws -> [Date] {
        let calendar = try gregorian(identifier)
        let first = calendar.startOfDay(for: date)
        return try (0..<count).map { offset in
            try #require(calendar.date(byAdding: .day, value: offset, to: first))
        }
    }

    private func week(_ starts: [Date]) -> [WeatherDaySummary] {
        starts.map { start in
            WeatherDaySummary(
                date: start,
                symbolName: "sun.max.fill",
                highTemperature: Measurement(value: 18, unit: UnitTemperature.celsius),
                lowTemperature: Measurement(value: 9, unit: UnitTemperature.celsius),
                precipitationChance: 0
            )
        }
    }
}

// MARK: - Which day a reading is about

extension WeatherForecastDayTests {
    /// The case the issue executed. At 10:00Z it is Friday the 23rd in both
    /// Berlin and Tokyo, but Tokyo's Friday began at 15:00Z on Thursday —
    /// Thursday in Berlin's calendar — so a calendar-day match chose Tokyo's
    /// Saturday, five hours in the future, and its sunset.
    @Test("Tokyo read from Berlin is about Tokyo's day in progress")
    func aForecastAheadOfTheReader() throws {
        let reading = try instant("2026-10-23T10:00:00Z")
        let starts = try midnights(7, in: "Asia/Tokyo", from: reading)
        #expect(starts.first == (try instant("2026-10-22T15:00:00Z")))
        let berlin = try gregorian("Europe/Berlin")

        #expect(WeatherForecastDay.index(containing: reading, startingAt: starts, calendar: berlin) == 0)
        #expect(
            starts.firstIndex { berlin.isDate($0, inSameDayAs: reading) } == 1,
            "the predicate this replaced, which picked tomorrow"
        )
    }

    /// Sixteen hours apart, which is further than half a day, so no rounding
    /// of a start to the nearest midnight in the reader's zone lands on the
    /// right day: Tokyo's Friday begins at 08:00 on Thursday in California.
    @Test("Tokyo read from California is about Tokyo's day, not California's")
    func oppositeSidesOfThePacific() throws {
        // Friday 23rd, 03:00 in Los Angeles; Friday 23rd, 19:00 in Tokyo.
        let reading = try instant("2026-10-23T10:00:00Z")
        let starts = try midnights(7, in: "Asia/Tokyo", from: reading)
        let california = try gregorian("America/Los_Angeles")

        let index = try #require(
            WeatherForecastDay.index(containing: reading, startingAt: starts, calendar: california)
        )
        let tokyo = try gregorian("Asia/Tokyo")
        #expect(tokyo.component(.day, from: starts[index]) == 23)
        #expect(
            starts.firstIndex { california.isDate($0, inSameDayAs: reading) } == 1,
            "the predicate this replaced, which picked Tokyo's Saturday"
        )
    }

    /// The other direction. In Tokyo it is Friday afternoon; in Honolulu it
    /// is still Thursday night, and Honolulu's Friday starts at 19:00 on
    /// Tokyo's Friday — today in the reader's calendar, and still three hours
    /// away.
    @Test("a forecast behind the reader is about its own day, not a future one")
    func aForecastBehindTheReader() throws {
        let reading = try instant("2026-10-23T07:00:00Z")
        let starts = try midnights(7, in: "Pacific/Honolulu", from: reading)
        let tokyo = try gregorian("Asia/Tokyo")

        let index = try #require(
            WeatherForecastDay.index(containing: reading, startingAt: starts, calendar: tokyo)
        )
        let honolulu = try gregorian("Pacific/Honolulu")
        #expect(honolulu.component(.day, from: starts[index]) == 22)
        #expect(
            starts.firstIndex { tokyo.isDate($0, inSameDayAs: reading) } == 1,
            "the predicate this replaced, which picked a day still to come"
        )
    }

    /// A forecast whose first day has not begun yet covers nothing about the
    /// reading. ``WeatherDaylight/forDay(of:in:calendar:)`` falls back to the
    /// first day from here, which is the answer it has always given.
    @Test("a reading before the first day falls in none of them")
    func aReadingBeforeTheForecast() throws {
        let reading = try instant("2026-10-23T10:00:00Z")
        let tomorrow = try instant("2026-10-24T10:00:00Z")
        let starts = try midnights(3, in: "Europe/Berlin", from: tomorrow)

        #expect(
            WeatherForecastDay.index(
                containing: reading,
                startingAt: starts,
                calendar: try gregorian("Europe/Berlin")
            ) == nil
        )
    }

    /// Berlin's clocks go back at 01:00Z on 25 October 2026, so that day is
    /// twenty-five hours long. Read from Tokyo, which keeps no daylight
    /// saving, a day of 24 hours in the reader's calendar would end Berlin's
    /// Sunday an hour early and leave its last hour in no day at all.
    @Test("a twenty-five hour day keeps its last hour")
    func theClocksGoBackWhereTheForecastIs() throws {
        let saturday = try instant("2026-10-24T12:00:00Z")
        let starts = try midnights(4, in: "Europe/Berlin", from: saturday)
        // 23:30 on Sunday in Berlin, which is now an hour behind UTC.
        let lateSunday = try instant("2026-10-25T22:30:00Z")
        let tokyo = try gregorian("Asia/Tokyo")

        #expect(starts[2].timeIntervalSince(starts[1]) == 25 * 3600)
        #expect(WeatherForecastDay.index(containing: lateSunday, startingAt: starts, calendar: tokyo) == 1)
        #expect(
            WeatherForecastDay.index(containing: starts[2], startingAt: starts, calendar: tokyo) == 2,
            "and Monday starts at its own midnight, not an hour before it"
        )
    }

    /// The last day has no next start, so it is the one place a calendar is
    /// asked how long a day is.
    @Test("the last day ends a calendar day after it starts")
    func theLastDayAsksTheCalendar() throws {
        let reading = try instant("2026-10-23T10:00:00Z")
        let starts = try midnights(2, in: "Asia/Tokyo", from: reading)
        let tokyo = try gregorian("Asia/Tokyo")

        #expect(
            WeatherForecastDay.end(ofDayAt: 1, startingAt: starts, calendar: tokyo)
                == tokyo.date(byAdding: .day, value: 1, to: starts[1])
        )
        let afterTheEnd = try instant("2026-10-24T15:00:00Z")
        #expect(WeatherForecastDay.index(containing: afterTheEnd, startingAt: starts, calendar: tokyo) == nil)
    }
}

// MARK: - The week strip

extension WeatherForecastDayTests {
    /// The strip keeps Tokyo's Friday for a Berlin reader on Friday, and
    /// calls it *Today* — not Saturday, which is where a calendar-day test
    /// put the word.
    @Test("the day in progress abroad is the one the strip calls Today")
    func todayAbroad() throws {
        let reading = try instant("2026-10-23T10:00:00Z")
        let week = week(try midnights(7, in: "Asia/Tokyo", from: reading))

        let upcoming = WeatherDaySummary.upcoming(
            in: week,
            asOf: reading,
            calendar: try gregorian("Europe/Berlin")
        )
        #expect(upcoming.count == 7)
        #expect(upcoming.map { $0.isInProgress(asOf: reading) } == [true] + Array(repeating: false, count: 6))
    }

    /// Once Tokyo's Friday has ended — 15:00Z, which is the middle of
    /// Berlin's Friday afternoon — the strip opens on Saturday, and that is
    /// the day in progress.
    @Test("a day abroad is dropped when it ends there, not here")
    func aDayAbroadEndsAtItsOwnMidnight() throws {
        let reading = try instant("2026-10-23T15:30:00Z")
        let starts = try midnights(7, in: "Asia/Tokyo", from: try instant("2026-10-23T10:00:00Z"))

        let upcoming = WeatherDaySummary.upcoming(
            in: week(starts),
            asOf: reading,
            calendar: try gregorian("Europe/Berlin")
        )
        #expect(upcoming.first?.date == starts[1])
        #expect(upcoming.first?.isInProgress(asOf: reading) == true)
    }

    /// Named in the forecast's zone. Tokyo's Friday starts on a Thursday
    /// afternoon anywhere west of it, and formatted there every row of the
    /// strip was a weekday early. Compared against the same formatter on an
    /// instant that is Friday or Thursday in UTC, so the test holds in every
    /// locale the suite runs in.
    @MainActor
    @Test("Tokyo's Friday is named Friday wherever it is read")
    func weekdaysAreTheForecastsOwn() throws {
        let fridayInTokyo = try instant("2026-10-22T15:00:00Z")
        let tokyo = try zone("Asia/Tokyo")
        let friday = try instant("2026-10-23T12:00:00Z")
        let thursday = try instant("2026-10-22T12:00:00Z")

        #expect(
            WeatherDetailView.weekday(fridayInTokyo, isToday: false, in: tokyo)
                == WeatherDetailView.weekday(friday, isToday: false, in: .gmt)
        )
        #expect(
            WeatherDetailView.spokenWeekday(fridayInTokyo, isToday: false, in: tokyo)
                == WeatherDetailView.spokenWeekday(friday, isToday: false, in: .gmt)
        )
        #expect(
            WeatherDetailView.weekday(fridayInTokyo, isToday: false, in: try zone("Europe/Berlin"))
                == WeatherDetailView.weekday(thursday, isToday: false, in: .gmt),
            "the reader's zone, which is what the strip used to name it in"
        )
    }
}
