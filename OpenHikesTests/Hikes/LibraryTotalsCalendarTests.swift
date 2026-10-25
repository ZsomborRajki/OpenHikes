//
//  LibraryTotalsCalendarTests.swift
//  OpenHikesTests
//
//  Totals' months are the hiker's calendar's, and a year is not always
//  twelve of them: a Hebrew leap year has thirteen, every Ethiopic year has
//  thirteen, and a Chinese leap year repeats one. Whatever a year counts has
//  to be in one of its bars (#1079).
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Library totals in the hiker's calendar")
struct LibraryTotalsCalendarTests {
    private static func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        in calendar: Calendar,
        leap: Bool = false
    ) throws -> Date {
        var parts = DateComponents(year: year, month: month, day: day)
        parts.isLeapMonth = leap
        return try #require(calendar.date(from: parts))
    }

    private static func hike(on date: Date, meters: Double) -> LibraryHikeFacts {
        LibraryHikeFacts(
            hikeID: UUID(),
            title: "Walk",
            date: date,
            distanceMeters: meters,
            climbMeters: 0,
            highestMeters: nil,
            movingSeconds: 3600,
            clock: DateInterval(start: date, duration: 3600),
            isFromCommunity: false
        )
    }

    private static func sum(_ months: [LibraryTotals.MonthDistance]) -> Double {
        months.reduce(0) { $0 + $1.distanceMeters }
    }

    private static func numbers(_ months: [LibraryTotals.MonthDistance]) -> [Int] {
        months.map(\.month.number)
    }

    // MARK: Every month the year has

    @Test("a Gregorian year is twelve months, January first, and its bars add up to the year")
    func gregorianYear() throws {
        let gregorian = Self.calendar(.gregorian)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(2026, 1, 1, in: gregorian), meters: 300),
                Self.hike(on: Self.date(2026, 12, 31, in: gregorian), meters: 400),
                Self.hike(on: Self.date(2025, 12, 31, in: gregorian), meters: 700),
            ],
            walks: [],
            year: 2026,
            calendar: gregorian
        )
        #expect(Self.numbers(totals.monthsThisYear) == Array(1...12))
        #expect(totals.monthsThisYear.first?.distanceMeters == 300)
        #expect(totals.monthsThisYear.last?.distanceMeters == 400)
        #expect(Self.sum(totals.monthsThisYear) == totals.thisYear.distanceMeters)
        #expect(Self.sum(totals.monthsLastYear) == totals.lastYear.distanceMeters)
        #expect(totals.monthColumns.count == 12)
    }

    /// The issue's reproduction: Elul, the thirteenth month by Foundation's
    /// count, counted in the year's distance and in none of its bars.
    @Test("a Hebrew leap year has thirteen bars, and an outing in Elul is in the last of them")
    func hebrewLeapYear() throws {
        let hebrew = Self.calendar(.hebrew)
        let elul = try Self.date(5787, 13, 1, in: hebrew)
        let totals = LibraryTotals(
            hikes: [Self.hike(on: elul, meters: 1000)], walks: [], year: 5787, calendar: hebrew
        )
        #expect(totals.thisYear.distanceMeters == 1000)
        #expect(Self.sum(totals.monthsThisYear) == 1000)
        #expect(Self.numbers(totals.monthsThisYear) == Array(1...13))
        #expect(totals.monthsThisYear.last?.distanceMeters == 1000)
    }

    /// Foundation numbers Adar I as 6, which a common year skips, so a
    /// common year's twelve months are numbered one to thirteen as well.
    @Test("a common Hebrew year has the twelve months it has, and the chart lines both years up by month")
    func hebrewCommonYearBesideALeapOne() throws {
        let hebrew = Self.calendar(.hebrew)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(5787, 6, 10, in: hebrew), meters: 200),
                Self.hike(on: Self.date(5787, 7, 10, in: hebrew), meters: 300),
                Self.hike(on: Self.date(5786, 7, 10, in: hebrew), meters: 500),
                Self.hike(on: Self.date(5786, 13, 10, in: hebrew), meters: 800),
            ],
            walks: [],
            year: 5787,
            calendar: hebrew
        )
        #expect(Self.numbers(totals.monthsLastYear) == [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13])
        #expect(Self.sum(totals.monthsLastYear) == totals.lastYear.distanceMeters)
        #expect(Self.sum(totals.monthsThisYear) == totals.thisYear.distanceMeters)

        let columns = totals.monthColumns
        #expect(columns.map(\.month.number) == Array(1...13))
        let adarI = try #require(columns.first { $0.month.number == 6 })
        #expect(adarI.thisYear?.distanceMeters == 200)
        #expect(adarI.lastYear == nil)
        let adar = try #require(columns.first { $0.month.number == 7 })
        #expect(adar.thisYear?.distanceMeters == 300)
        #expect(adar.lastYear?.distanceMeters == 500)
    }

    @Test("every Ethiopic year has a thirteenth month, and it has its bar")
    func ethiopicPagumen() throws {
        let ethiopic = Self.calendar(.ethiopicAmeteMihret)
        let pagumen = try Self.date(2018, 13, 2, in: ethiopic)
        let totals = LibraryTotals(
            hikes: [Self.hike(on: pagumen, meters: 600)], walks: [], year: 2018, calendar: ethiopic
        )
        #expect(Self.numbers(totals.monthsThisYear) == Array(1...13))
        #expect(totals.monthsThisYear.last?.distanceMeters == 600)
        #expect(Self.sum(totals.monthsThisYear) == totals.thisYear.distanceMeters)
    }

    /// The Chinese year 42 (2025) repeats its sixth month. The repeat is a
    /// month of its own, after the one it repeats, not a second helping of it.
    @Test("a Chinese leap month is its own bar, after the month it repeats")
    func chineseLeapMonth() throws {
        let chinese = Self.calendar(.chinese)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(42, 6, 10, in: chinese), meters: 100),
                Self.hike(on: Self.date(42, 6, 10, in: chinese, leap: true), meters: 900),
            ],
            walks: [],
            year: 42,
            calendar: chinese
        )
        #expect(totals.monthsThisYear.count == 13)
        let sixth = try #require(totals.monthsThisYear.firstIndex { $0.month.number == 6 })
        #expect(totals.monthsThisYear[sixth].month.isLeap == false)
        #expect(totals.monthsThisYear[sixth].distanceMeters == 100)
        #expect(totals.monthsThisYear[sixth + 1].month.isLeap)
        #expect(totals.monthsThisYear[sixth + 1].distanceMeters == 900)
        #expect(Self.sum(totals.monthsThisYear) == totals.thisYear.distanceMeters)
    }

    @Test("each month's span is the calendar's, so the bar can be named for it")
    func monthSpans() throws {
        let hebrew = Self.calendar(.hebrew)
        let totals = LibraryTotals(hikes: [], walks: [], year: 5787, calendar: hebrew)
        let start = try Self.date(5787, 1, 1, in: hebrew)
        #expect(totals.monthsThisYear.first?.interval.start == start)
        for (month, next) in zip(totals.monthsThisYear, totals.monthsThisYear.dropFirst()) {
            #expect(month.interval.end == next.interval.start)
        }
        let end = try #require(hebrew.dateInterval(of: .year, for: start)?.end)
        #expect(totals.monthsThisYear.last?.interval.end == end)
    }
}
