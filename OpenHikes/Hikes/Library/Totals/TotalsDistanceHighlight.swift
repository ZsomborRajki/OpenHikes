//
//  TotalsDistanceHighlight.swift
//  OpenHikes
//
//  The one thing *Totals* says in a sentence: whether this year, so far, is
//  ahead of last year as far as last year had got by this day.
//
//  It is Health's highlight: a sentence over two bars, one a year. Health
//  holds a year against a year by their averages, since half a year of
//  steps a day and a whole one compare. A year of hiking is a sum, and a
//  sum in March against a whole year says only that it is March. So last
//  year is cut at this day (``LibraryTotals/lastYearByNow``), and the two
//  figures are what was walked by the same day of each.
//
//  A value, so that what the sentence claims is asserted without a screen:
//  when there is nothing to say, and how near two years have to be before
//  they are called level.
//

import Foundation

nonisolated struct TotalsDistanceHighlight: Equatable, Sendable {
    /// Where this year stands against last year by this day.
    enum Standing: Equatable, Sendable {
        case ahead
        case behind
        case level
    }

    /// How near the shorter year has to come to the longer before the two
    /// are called level, as a share of the longer. A hike more or less in
    /// several hundred kilometres is not a year ahead or behind.
    static let levelTolerance = 0.05

    let standing: Standing
    let thisYearMeters: Double
    /// By this day last year.
    let lastYearMeters: Double

    /// `nil` when there is nothing to hold against anything: a hiker with
    /// no last year (``LibraryTotals/hasLastYear``), and a day by which
    /// neither year has a hike in it.
    init?(totals: LibraryTotals) {
        guard totals.hasLastYear else { return nil }
        let now = totals.thisYear.distanceMeters
        let then = totals.lastYearByNow.distanceMeters
        let longer = max(now, then)
        guard longer > 0 else { return nil }
        thisYearMeters = now
        lastYearMeters = then
        if abs(now - then) <= longer * Self.levelTolerance {
            standing = .level
        } else {
            standing = now > then ? .ahead : .behind
        }
    }

    /// How much of the longer bar's length each year's bar is, from 0 to 1.
    var thisYearShare: Double { thisYearMeters / max(thisYearMeters, lastYearMeters) }
    var lastYearShare: Double { lastYearMeters / max(thisYearMeters, lastYearMeters) }
}
