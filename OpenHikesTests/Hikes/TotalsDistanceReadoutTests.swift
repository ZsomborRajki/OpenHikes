//
//  TotalsDistanceReadoutTests.swift
//  OpenHikesTests
//
//  The figures over *Totals*' month chart: the year, and last year beside
//  it, or the month under a finger in each. What they must never do is hold
//  a first year against a year of nothing, or write a month a year does not
//  have as a month nothing was walked in.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Totals distance readout")
struct TotalsDistanceReadoutTests {
    private typealias Side = TotalsDistanceReadout.Side

    private static let english = Locale(identifier: "en_US")

    private static func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = .gmt
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day)))
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

    /// March and May of 2026, and March of 2025 when `lastYearMeters` is
    /// given, summed in June 2026.
    private static func twoYears(lastYearMeters: Double? = 500) throws -> LibraryTotals {
        let gregorian = calendar(.gregorian)
        var hikes = try [
            hike(on: date(2026, 3, 10, in: gregorian), meters: 4000),
            hike(on: date(2026, 5, 2, in: gregorian), meters: 2500),
        ]
        if let lastYearMeters {
            try hikes.append(hike(on: date(2025, 3, 20, in: gregorian), meters: lastYearMeters))
        }
        return try LibraryTotals(
            hikes: hikes, walks: [], asOf: date(2026, 6, 1, in: gregorian), calendar: gregorian
        )
    }

    private static func key(ofMonth number: Int, in totals: LibraryTotals) throws -> String {
        try #require(totals.monthColumns.first { $0.month.number == number }).month.chartKey
    }

    @Test("with no finger on the chart, each year reads its whole distance under its own number")
    func wholeYears() throws {
        let readout = try TotalsDistanceReadout(totals: Self.twoYears(), selectedKey: nil, locale: Self.english)
        #expect(readout.thisYear == Side(label: "2026", meters: 6500))
        #expect(readout.lastYear == Side(label: "2025", meters: 500))
    }

    @Test("a first year reads alone, with no year of nothing beside it")
    func firstYear() throws {
        let totals = try Self.twoYears(lastYearMeters: nil)
        #expect(!totals.hasLastYear)
        let readout = TotalsDistanceReadout(totals: totals, selectedKey: nil, locale: Self.english)
        #expect(readout.thisYear == Side(label: "2026", meters: 6500))
        #expect(readout.lastYear == nil)

        let march = try TotalsDistanceReadout(
            totals: totals, selectedKey: Self.key(ofMonth: 3, in: totals), locale: Self.english
        )
        #expect(march.thisYear == Side(label: "Mar 2026", meters: 4000))
        #expect(march.lastYear == nil)
    }

    @Test("a finger on a month reads that month in each year, each named with its own year")
    func selectedMonth() throws {
        let totals = try Self.twoYears()
        let readout = try TotalsDistanceReadout(
            totals: totals, selectedKey: Self.key(ofMonth: 3, in: totals), locale: Self.english
        )
        #expect(readout.thisYear == Side(label: "Mar 2026", meters: 4000))
        #expect(readout.lastYear == Side(label: "Mar 2025", meters: 500))
    }

    /// December 2026 has not come by June, and still has its bar: its
    /// figure is nothing walked, which is a figure.
    @Test("a month nothing was walked in reads as nothing walked, in both years")
    func emptyMonth() throws {
        let totals = try Self.twoYears()
        let readout = try TotalsDistanceReadout(
            totals: totals, selectedKey: Self.key(ofMonth: 12, in: totals), locale: Self.english
        )
        #expect(readout.thisYear == Side(label: "Dec 2026", meters: 0))
        #expect(readout.lastYear == Side(label: "Dec 2025", meters: 0))
    }

    @Test("the month is named in the reader's language")
    func monthInTheReadersLanguage() throws {
        let totals = try Self.twoYears()
        let readout = try TotalsDistanceReadout(
            totals: totals, selectedKey: Self.key(ofMonth: 3, in: totals), locale: Locale(identifier: "de_DE")
        )
        #expect(readout.thisYear.label == "März 2026")
    }

    /// 5787 is a Hebrew leap year and has an Adar I, Foundation's month 6,
    /// which 5786 skips. Under a finger on it, last year has no month to
    /// read: no figure, under the bare year.
    @Test("a month only one of the years has reads as no figure in the other")
    func monthOneYearLacks() throws {
        let hebrew = Self.calendar(.hebrew)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(5787, 6, 10, in: hebrew), meters: 200),
                Self.hike(on: Self.date(5786, 7, 10, in: hebrew), meters: 500),
            ],
            walks: [],
            asOf: Self.date(5787, 8, 1, in: hebrew),
            calendar: hebrew
        )
        let readout = try TotalsDistanceReadout(
            totals: totals, selectedKey: Self.key(ofMonth: 6, in: totals), locale: Self.english
        )
        #expect(readout.thisYear.meters == 200)
        #expect(readout.thisYear.label.contains("Adar I"))
        #expect(readout.thisYear.label.contains("5787"))
        #expect(readout.lastYear == Side(label: "5786", meters: nil))
    }

    @Test("a selection that names no month of either year reads as the whole year")
    func unknownKey() throws {
        let totals = try Self.twoYears()
        let whole = TotalsDistanceReadout(totals: totals, selectedKey: nil, locale: Self.english)
        #expect(TotalsDistanceReadout(totals: totals, selectedKey: "40-false", locale: Self.english) == whole)
    }
}
