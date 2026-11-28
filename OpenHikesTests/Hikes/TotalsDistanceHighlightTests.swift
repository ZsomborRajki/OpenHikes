//
//  TotalsDistanceHighlightTests.swift
//  OpenHikesTests
//
//  *Totals* says in a sentence whether this year is ahead of last year, and
//  a sentence is a claim. So what it is made from is held here: last year
//  cut at this day, never the whole of it, how near two years must be to
//  be called level, and the days on which there is nothing to say.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Totals distance highlight")
struct TotalsDistanceHighlightTests {
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

    /// Summed on 1 June 2026: `thisYear` walked in March 2026, `byNow` in
    /// February 2025 and `later` in September 2025, a month this year has
    /// not reached.
    private static func totals(thisYear: Double?, byNow: Double?, later: Double? = nil) throws -> LibraryTotals {
        let gregorian = calendar(.gregorian)
        let walked: [(Double?, Date)] = try [
            (thisYear, date(2026, 3, 10, in: gregorian)),
            (byNow, date(2025, 2, 20, in: gregorian)),
            (later, date(2025, 9, 5, in: gregorian)),
        ]
        let hikes = walked.compactMap { meters, day in meters.map { hike(on: day, meters: $0) } }
        return try LibraryTotals(hikes: hikes, walks: [], asOf: date(2026, 6, 1, in: gregorian), calendar: gregorian)
    }

    // MARK: Last year, by this day

    /// The whole of last year is 10 km and this year so far is 4: held
    /// against the whole, June is always behind. By this day last year had
    /// 1 km, and this year is ahead of that.
    @Test("this year is held against last year by this day, not against the whole of it")
    func lastYearIsCutAtThisDay() throws {
        let totals = try Self.totals(thisYear: 4000, byNow: 1000, later: 9000)
        #expect(totals.lastYear.distanceMeters == 10_000)
        #expect(totals.lastYearByNow.distanceMeters == 1000)
        #expect(totals.lastYearByNow.outings == 1)

        let highlight = try #require(TotalsDistanceHighlight(totals: totals))
        #expect(highlight.standing == .ahead)
        #expect(highlight.thisYearMeters == 4000)
        #expect(highlight.lastYearMeters == 1000)
    }

    @Test("a hike a year ago to the moment is last year's by now, and one a moment later is not")
    func theDayItself() throws {
        let gregorian = Self.calendar(.gregorian)
        let now = try Self.date(2026, 6, 1, in: gregorian).addingTimeInterval(12 * 3600)
        let yearAgo = try #require(gregorian.date(byAdding: .year, value: -1, to: now))
        let totals = LibraryTotals(
            hikes: [
                Self.hike(on: yearAgo, meters: 700),
                Self.hike(on: yearAgo.addingTimeInterval(1), meters: 5000),
            ],
            walks: [],
            asOf: now,
            calendar: gregorian
        )
        #expect(totals.lastYearByNow.distanceMeters == 700)
        #expect(totals.lastYear.distanceMeters == 5700)
    }

    /// Elul is Foundation's month 13 in a Hebrew leap year and in a common
    /// one, so the first of Elul 5787 is held against the first of Elul
    /// 5786, though 5787 has had a month more by then.
    @Test("this day last year is the calendar's, across a leap month")
    func hebrewLeapYear() throws {
        let hebrew = Self.calendar(.hebrew)
        let totals = try LibraryTotals(
            hikes: [
                Self.hike(on: Self.date(5786, 12, 10, in: hebrew), meters: 800),
                Self.hike(on: Self.date(5786, 13, 20, in: hebrew), meters: 6000),
            ],
            walks: [],
            asOf: Self.date(5787, 13, 1, in: hebrew),
            calendar: hebrew
        )
        #expect(totals.lastYearByNow.distanceMeters == 800)
    }

    // MARK: What the sentence says

    @Test("this year is behind when last year had gone farther by this day")
    func behind() throws {
        let highlight = try #require(TotalsDistanceHighlight(totals: Self.totals(thisYear: 1000, byNow: 4000)))
        #expect(highlight.standing == .behind)
        #expect(highlight.thisYearShare.isApproximatelyEqual(to: 0.25, absoluteTolerance: 1e-9))
        #expect(highlight.lastYearShare == 1)
    }

    @Test("the longer year's bar is the whole length, and the shorter its share of it")
    func shares() throws {
        let highlight = try #require(TotalsDistanceHighlight(totals: Self.totals(thisYear: 4000, byNow: 1000)))
        #expect(highlight.thisYearShare == 1)
        #expect(highlight.lastYearShare.isApproximatelyEqual(to: 0.25, absoluteTolerance: 1e-9))
    }

    /// 5% of the longer year, either way round. 960 m against 1000 m is one
    /// short hike's difference; 940 m is past it.
    @Test("two years within a twentieth of each other are level, whichever is the longer")
    func level() throws {
        #expect(try TotalsDistanceHighlight(totals: Self.totals(thisYear: 1000, byNow: 960))?.standing == .level)
        #expect(try TotalsDistanceHighlight(totals: Self.totals(thisYear: 960, byNow: 1000))?.standing == .level)
        #expect(try TotalsDistanceHighlight(totals: Self.totals(thisYear: 1000, byNow: 1000))?.standing == .level)
        #expect(try TotalsDistanceHighlight(totals: Self.totals(thisYear: 1000, byNow: 940))?.standing == .ahead)
        #expect(try TotalsDistanceHighlight(totals: Self.totals(thisYear: 940, byNow: 1000))?.standing == .behind)
    }

    @Test("a year with nothing in it yet is behind one that had something by this day")
    func nothingThisYear() throws {
        let highlight = try #require(TotalsDistanceHighlight(totals: Self.totals(thisYear: nil, byNow: 500)))
        #expect(highlight.standing == .behind)
        #expect(highlight.thisYearShare == 0)
        #expect(highlight.lastYearShare == 1)
    }

    /// Last year's first hike was in September. By June neither year is
    /// behind the other, but this year has walked and last year had not.
    @Test("a year that has walked is ahead of one that had not yet by this day")
    func lastYearHadNotBegun() throws {
        let totals = try Self.totals(thisYear: 300, byNow: nil, later: 9000)
        let highlight = try #require(TotalsDistanceHighlight(totals: totals))
        #expect(highlight.standing == .ahead)
        #expect(highlight.lastYearMeters == 0)
        #expect(highlight.lastYearShare == 0)
    }

    // MARK: When there is nothing to say

    @Test("a first year has no highlight: there is no last year to hold it against")
    func firstYear() throws {
        #expect(try TotalsDistanceHighlight(totals: Self.totals(thisYear: 4000, byNow: nil)) == nil)
    }

    /// Both bars would be nothing, and "about as far" of nothing is not a
    /// finding.
    @Test("a day by which neither year has a hike in it has no highlight")
    func neitherYearByNow() throws {
        #expect(try TotalsDistanceHighlight(totals: Self.totals(thisYear: nil, byNow: nil, later: 9000)) == nil)
    }
}
