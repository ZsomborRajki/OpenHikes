//
//  TotalsDistanceReadout.swift
//  OpenHikes
//
//  What stands over *Totals*' month chart: how far was walked this year, and
//  last year beside it. With a finger on the chart it is the month under the
//  finger instead, each year's figure named for its own month, the way
//  Health's charts read out the bar that is touched.
//
//  A value, so that what the figures say is asserted without a chart: which
//  year is left out, what a month only one year has reads as, and what a
//  selection that names no month falls back to.
//

import Foundation

nonisolated struct TotalsDistanceReadout: Equatable, Sendable {
    /// One year's figure.
    struct Side: Equatable, Sendable {
        /// The year, or the month with its year.
        let label: String
        /// `nil` for a month this year does not have: a common Hebrew year
        /// has no Adar I to stand beside a leap year's.
        let meters: Double?
    }

    let thisYear: Side
    /// `nil` when nothing was walked last year — see
    /// ``LibraryTotals/hasLastYear``.
    let lastYear: Side?

    /// - Parameter selectedKey: The ``LibraryTotals/Month/chartKey`` of the
    ///   bar under the finger, or `nil` for the whole year. A key that is no
    ///   month of either year reads as the whole year too.
    init(totals: LibraryTotals, selectedKey: String?, locale: Locale) {
        let column = selectedKey.flatMap { key in
            totals.monthColumns.first { $0.month.chartKey == key }
        }
        guard let column else {
            thisYear = Side(label: String(totals.year), meters: totals.thisYear.distanceMeters)
            lastYear = totals.hasLastYear
                ? Side(label: String(totals.previousYear), meters: totals.lastYear.distanceMeters)
                : nil
            return
        }
        thisYear = Self.side(column.thisYear, year: totals.year, totals: totals, locale: locale)
        lastYear = totals.hasLastYear
            ? Self.side(column.lastYear, year: totals.previousYear, totals: totals, locale: locale)
            : nil
    }

    private static func side(
        _ month: LibraryTotals.MonthDistance?,
        year: Int,
        totals: LibraryTotals,
        locale: Locale
    ) -> Side {
        guard let month else { return Side(label: String(year), meters: nil) }
        return Side(label: totals.nameWithYear(of: month, locale: locale), meters: month.distanceMeters)
    }
}
