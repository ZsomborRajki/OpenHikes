//
//  TotalsDistanceReadout.swift
//  OpenHikes
//
//  What stands over *Totals*' month chart: how far was walked this year, and
//  last year beside it. With a finger on the chart it is the month under the
//  finger instead, the way Health's charts read out the bar that is touched.
//
//  Each figure is named for its year, and the name is the same with a finger
//  on the chart as without: the name, with its dot, is what says which
//  figure is which year's, so it must not change under the finger. The
//  month is named once, beside the card's heading — see
//  ``LibraryTotals/yearName`` for why it is never a month with its year.
//
//  A value, so that what the figures say is asserted without a chart: which
//  year is left out, what a month only one year has reads as, and what a
//  selection that names no month falls back to.
//

import Foundation

nonisolated struct TotalsDistanceReadout: Equatable, Sendable {
    /// One year's figure.
    struct Side: Equatable, Sendable {
        /// The year's name, whatever is selected.
        let label: String
        /// `nil` for a month this year does not have: a common Hebrew year
        /// has no Adar I to stand beside a leap year's.
        let meters: Double?
    }

    /// The month under the finger, named in full, or `nil` for the whole
    /// year. Named from this year's month where it has one, as the chart's
    /// axis names the column: one number can be two months, as a Hebrew
    /// year's 7 is Adar, or Adar II in a leap year.
    let month: String?
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
        guard let column, let named = column.thisYear ?? column.lastYear else {
            month = nil
            thisYear = Side(label: totals.yearName, meters: totals.thisYear.distanceMeters)
            lastYear = totals.hasLastYear
                ? Side(label: totals.previousYearName, meters: totals.lastYear.distanceMeters)
                : nil
            return
        }
        month = totals.name(of: named, width: .wide, locale: locale)
        thisYear = Side(label: totals.yearName, meters: column.thisYear?.distanceMeters)
        lastYear = totals.hasLastYear
            ? Side(label: totals.previousYearName, meters: column.lastYear?.distanceMeters)
            : nil
    }
}
