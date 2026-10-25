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
    private static func calendar(_ identifier: Calendar.Identifier, zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        in calendar: Calendar
    ) throws -> Date {
        let parts = DateComponents(year: year, month: month, day: day)
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
            asOf: Self.date(2026, 6, 1, in: gregorian),
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
            hikes: [Self.hike(on: elul, meters: 1000)], walks: [], asOf: elul, calendar: hebrew
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
            asOf: Self.date(5787, 8, 1, in: hebrew),
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
            hikes: [Self.hike(on: pagumen, meters: 600)], walks: [], asOf: pagumen, calendar: ethiopic
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
        let gregorian = Self.calendar(.gregorian)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(2025, 7, 5, in: gregorian), meters: 100),
                Self.hike(on: Self.date(2025, 8, 3, in: gregorian), meters: 900),
            ],
            walks: [],
            asOf: Self.date(2025, 8, 3, in: gregorian),
            calendar: chinese
        )
        #expect(totals.monthsThisYear.count == 13)
        let sixth = try #require(totals.monthsThisYear.firstIndex { $0.month.number == 6 })
        #expect(totals.monthsThisYear[sixth].month.isLeap == false)
        #expect(totals.monthsThisYear[sixth].distanceMeters == 100)
        #expect(totals.monthsThisYear[sixth + 1].month.isLeap)
        #expect(totals.monthsThisYear[sixth + 1].distanceMeters == 900)
        #expect(Self.sum(totals.monthsThisYear) == totals.thisYear.distanceMeters)
        #expect(totals.monthsThisYear[sixth].month.chartKey != totals.monthsThisYear[sixth + 1].month.chartKey)
        #expect(Set(totals.monthColumns.map(\.month.chartKey)).count == 13)
    }

    @Test("each month's span is the calendar's, so the bar can be named for it")
    func monthSpans() throws {
        let hebrew = Self.calendar(.hebrew)
        let start = try Self.date(5787, 1, 1, in: hebrew)
        let totals = LibraryTotals(hikes: [], walks: [], asOf: start, calendar: hebrew)
        #expect(totals.monthsThisYear.first?.interval.start == start)
        for (month, next) in zip(totals.monthsThisYear, totals.monthsThisYear.dropFirst()) {
            #expect(month.interval.end == next.interval.start)
        }
        let end = try #require(hebrew.dateInterval(of: .year, for: start)?.end)
        #expect(totals.monthsThisYear.last?.interval.end == end)
    }

    @Test("a repeated Japanese year number counts only the actual calendar year")
    func japaneseEra() throws {
        let gregorian = Self.calendar(.gregorian)
        let now = try Self.date(2026, 7, 1, in: gregorian)
        let start = try Self.date(2026, 1, 1, in: gregorian)
        let end = try Self.date(2027, 1, 1, in: gregorian)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(1996, 5, 1, in: gregorian), meters: 9000), // Heisei 8
                Self.hike(on: Self.date(2025, 12, 31, in: gregorian), meters: 700),
                Self.hike(on: Self.date(2026, 1, 1, in: gregorian), meters: 300), // Reiwa 8
                Self.hike(on: Self.date(2027, 1, 1, in: gregorian), meters: 8000),
            ],
            walks: [],
            asOf: now,
            calendar: Self.calendar(.japanese)
        )
        #expect(totals.year == 8)
        #expect(totals.thisYear.distanceMeters == 300)
        #expect(totals.lastYear.distanceMeters == 700)
        #expect(Self.sum(totals.monthsThisYear) == 300)
        #expect(totals.monthsThisYear.first?.interval.start == start)
        #expect(totals.monthsThisYear.last?.interval.end == end)
    }

    @Test("a Japanese era change keeps Foundation's whole calendar year and its real predecessor")
    func japaneseEraChange() throws {
        let gregorian = Self.calendar(.gregorian)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(2018, 6, 1, in: gregorian), meters: 40),
                Self.hike(on: Self.date(2019, 1, 2, in: gregorian), meters: 10),
                Self.hike(on: Self.date(2019, 5, 2, in: gregorian), meters: 20),
            ],
            walks: [],
            asOf: Self.date(2019, 5, 2, in: gregorian),
            calendar: Self.calendar(.japanese)
        )
        #expect(totals.year == 1)
        #expect(totals.previousYear == 30)
        #expect(totals.thisYear.distanceMeters == 30)
        #expect(totals.lastYear.distanceMeters == 40)
        #expect(Self.sum(totals.monthsThisYear) == 30)
        #expect(Self.sum(totals.monthsLastYear) == 40)
    }

    @Test("Chinese year one compares with year sixty of the previous cycle, not year zero")
    func chineseCycleChange() throws {
        let gregorian = Self.calendar(.gregorian)
        let start = try Self.date(2044, 1, 30, in: gregorian)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(1984, 3, 1, in: gregorian), meters: 9000),
                Self.hike(on: Self.date(2043, 3, 1, in: gregorian), meters: 200),
                Self.hike(on: Self.date(2044, 3, 1, in: gregorian), meters: 100),
            ],
            walks: [],
            asOf: Self.date(2044, 3, 1, in: gregorian),
            calendar: Self.calendar(.chinese)
        )
        #expect(totals.year == 1)
        #expect(totals.previousYear == 60)
        #expect(totals.thisYear.distanceMeters == 100)
        #expect(totals.lastYear.distanceMeters == 200)
        #expect(Self.sum(totals.monthsThisYear) == 100)
        #expect(Self.sum(totals.monthsLastYear) == 200)
        #expect(totals.monthsThisYear.first?.interval.start == start)
    }

    @Test("a time-zone change regroups the year and its months at their exact boundaries")
    func timeZoneChange() throws {
        let utc = Self.calendar(.gregorian)
        let newYork = Self.calendar(.gregorian, zone: "America/New_York")
        let now = try Self.date(2026, 6, 1, in: utc)
        let start = try Self.date(2026, 1, 1, in: newYork)
        let february = try Self.date(2026, 2, 1, in: newYork)
        let end = try Self.date(2027, 1, 1, in: newYork)
        let hikes = [
            Self.hike(on: start.addingTimeInterval(-1), meters: 500),
            Self.hike(on: start, meters: 100),
            Self.hike(on: february.addingTimeInterval(-1), meters: 200),
            Self.hike(on: february, meters: 400),
            Self.hike(on: end.addingTimeInterval(-1), meters: 300),
            Self.hike(on: end, meters: 9000),
        ]
        let totals = LibraryTotals(hikes: hikes, walks: [], asOf: now, calendar: newYork)
        let beforeZoneChange = LibraryTotals(hikes: hikes, walks: [], asOf: now, calendar: utc)
        let nextYear = LibraryTotals(hikes: hikes, walks: [], asOf: end, calendar: newYork)
        #expect(totals.thisYear.distanceMeters == 1000)
        #expect(totals.lastYear.distanceMeters == 500)
        #expect(totals.monthsThisYear[0].distanceMeters == 300)
        #expect(totals.monthsThisYear[1].distanceMeters == 400)
        #expect(totals.monthsThisYear[11].distanceMeters == 300)
        #expect(Self.sum(totals.monthsThisYear) == totals.thisYear.distanceMeters)
        #expect(nextYear.thisYear.distanceMeters == 9000)
        #expect(nextYear.lastYear.distanceMeters == 1000)
        #expect(nextYear.monthsThisYear[0].distanceMeters == 9000)
        #expect(beforeZoneChange.thisYear.distanceMeters == 1200)
        #expect(beforeZoneChange.monthsThisYear[1].distanceMeters == 600)
        for (month, next) in zip(totals.monthsThisYear, totals.monthsThisYear.dropFirst()) {
            #expect(month.interval.end == next.interval.start)
        }
    }

    @Test("month names use the sum's calendar even when the display locale prefers Gregorian")
    func monthNames() throws {
        let hebrew = Self.calendar(.hebrew, zone: "Pacific/Auckland")
        let totals = try LibraryTotals(hikes: [], walks: [], asOf: Self.date(5787, 6, 1, in: hebrew), calendar: hebrew)
        let adarI = try #require(totals.monthsThisYear.first { $0.month.number == 6 })
        let adarII = try #require(totals.monthsThisYear.first { $0.month.number == 7 })
        #expect(totals.name(of: adarI, width: .wide, locale: Locale(identifier: "en_US")) == "Adar I")
        #expect(totals.name(of: adarII, width: .wide, locale: Locale(identifier: "en_US")) == "Adar II")
        #expect(Set(totals.monthColumns.map(\.month.chartKey)).count == 13)
        let may = try Self.date(2026, 5, 1, in: Self.calendar(.gregorian))
        let gregorian = LibraryTotals(hikes: [], walks: [], asOf: may, calendar: Self.calendar(.gregorian))
        let month = gregorian.monthsThisYear[4]
        #expect(gregorian.name(of: month, width: .wide, locale: Locale(identifier: "en_US")) == "May")
        #expect(gregorian.name(of: month, width: .wide, locale: Locale(identifier: "fr_FR")) == "mai")
    }
}
