//
//  LibraryTotalsView.swift
//  OpenHikes
//
//  *Totals*: how far the hiker has walked this year, against last year, and
//  in all — see ``LibraryTotals`` for what counts and why.
//
//  The sums are worked out when the screen opens, off the main actor, and not
//  kept: a library changes by a hike at a time and re-summing one on open is
//  cheaper than keeping a second copy of every figure in step with it.
//
//  A library that could not be read says so, with *Try Again*, rather than
//  showing the zeroes an empty one would: nothing is summed from half a read.
//

import Charts
import OpenHikesData
import os
import SwiftData
import SwiftUI

struct LibraryTotalsView: View {
    private static let logger = Logger(subsystem: "OpenHikes", category: "LibraryTotals")

    /// Opens one of the records, the way a row of the library does.
    var onOpenHike: (Hike) -> Void = { _ in /* no-op default */ }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var totals: LibraryTotals?
    @State private var couldNotRead = false
    /// Bumped by *Try Again*, which re-runs the sum.
    @State private var attempt = 0

    private struct SumRequest: Hashable {
        let attempt: Int
        let calendar: Calendar

        init(attempt: Int, calendar: Calendar, timeZone: TimeZone) {
            self.attempt = attempt
            var calendar = calendar
            calendar.timeZone = timeZone
            self.calendar = calendar
        }
    }

    var body: some View {
        let request = SumRequest(attempt: attempt, calendar: calendar, timeZone: timeZone)
        ScrollView {
            if let totals {
                LibraryTotalsContent(totals: totals, onOpenHike: open)
                    .padding()
            } else if couldNotRead {
                ContentUnavailableView {
                    Label("Couldn’t Add Up Your Hikes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your library couldn’t be read just now.")
                } actions: {
                    Button("Try Again") { attempt += 1 }
                        .glassButtonStyle()
                        .accessibilityIdentifier("library-totals-retry")
                }
                .padding(.top, 40)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .navigationTitle("Totals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: request) { await sum(in: request.calendar) }
    }

    /// Replaces the figures with a fresh sum, or with the failure: figures
    /// from an earlier read are not left up as if they were this one's.
    private func sum(in calendar: Calendar) async {
        couldNotRead = false
        let date = Date.now
        do {
            let read = try await LibraryTotalsSweep.read(from: modelContext.container)
            try Task.checkCancellation()
            totals = LibraryTotals(hikes: read.hikes, walks: read.walks, asOf: date, calendar: calendar)
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error(
                "The library could not be read for its totals: \(error.localizedDescription, privacy: .public)"
            )
            totals = nil
            couldNotRead = true
        }
    }

    /// The record's hike, fetched here where the context is, or nothing for
    /// one deleted since the figures were summed.
    private func open(_ hikeID: UUID) {
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        guard let hike = try? modelContext.fetch(descriptor).first else { return }
        onOpenHike(hike)
    }
}

/// The figures, once there are some. Its own view so the loading state above
/// is the only thing the screen's own body decides.
private struct LibraryTotalsContent: View {
    private static let sectionSpacing: CGFloat = 28
    private static let headingSpacing: CGFloat = 12
    private static let footnoteSpacing: CGFloat = 8

    let totals: LibraryTotals
    let onOpenHike: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            section(String(totals.year)) {
                StatSummary(stats: Self.stats(totals.thisYear, comparedWith: totals.lastYear))
                LibraryMonthChart(totals: totals)
            }
            section("All Time") {
                StatSummary(stats: Self.stats(totals.allTime, comparedWith: nil))
            }
            if totals.longest != nil {
                section("Records") {
                    StatList {
                        record("Longest", totals.longest) { TotalsFormat.distance($0.distanceMeters) }
                        record("Highest", totals.highest) { TotalsFormat.height($0.highestMeters ?? 0) }
                        record("Steepest", totals.steepest) { TotalsFormat.height($0.climbMeters ?? 0) + " up" }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Self.footnoteSpacing) {
                Text(
                    "Recordings and GPX files with times count as hiked, "
                        + "and so does every activity along a saved trail. "
                        + "A trail you drew or saved counts once you hike it."
                )
                if totals.allTime.outingsWithoutClimb > 0 {
                    Text("""
                    Climb, Highest and Steepest leave out activities along trails \
                    that have changed since you hiked them.
                    """)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Self.headingSpacing) {
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    @ViewBuilder
    private func record(
        _ label: String,
        _ candidate: LibraryRecordCandidate?,
        value: (LibraryRecordCandidate) -> String
    ) -> some View {
        if let candidate {
            Button { onOpenHike(candidate.hikeID) } label: {
                StatRow(label: label, value: "\(candidate.title) · \(value(candidate))")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-record-\(label.lowercased())")
        }
    }

    private static func stats(_ figures: LibraryTotals.Figures, comparedWith last: LibraryTotals.Figures?) -> [Stat] {
        var stats = [
            Stat("Distance", TotalsFormat.distance(figures.distanceMeters), headline: true),
            Stat("Climb", TotalsFormat.height(figures.climbMeters), headline: true),
            Stat("Moving Time", HikeFormat.duration(figures.movingSeconds), headline: true),
            Stat("Activities", figures.outings.formatted()),
            Stat("Trails", figures.trails.formatted()),
        ]
        if let last {
            stats.append(Stat("Last Year", TotalsFormat.distance(last.distanceMeters)))
        }
        return stats
    }
}

/// Distance by month, this year beside last — the one comparison the screen
/// draws rather than states. This year is the point and wears the tint; last
/// year is context and is gray. A legend names both, so neither is carried by
/// colour alone, and every bar speaks its month and distance.
///
/// The months are the hiker's calendar's, as many as the two years have —
/// see ``LibraryTotals`` — and each is named from its own span, so a Hebrew
/// leap year's seventh month reads Adar II and a common year's Adar.
private struct LibraryMonthChart: View {
    /// Thin bars, the gap between a month's pair left by their width, and
    /// 4pt rounded tops.
    private static let barWidth = 0.8
    private static let cornerRadius: CGFloat = 4
    private static let height: CGFloat = 180
    private static let lastYearOpacity = 0.5

    let totals: LibraryTotals
    @Environment(\.locale) private var locale

    private struct Bar: Identifiable {
        /// What the bar is plotted against. The x axis is categorical, so a
        /// column needs a value of its own — the one-letter names are not:
        /// January, June and July would share a single "J" column.
        let column: String
        let series: String
        let month: LibraryTotals.MonthDistance
        var id: String { "\(series)-\(column)" }
    }

    /// One month's column, named from this year's month where it has one.
    private struct Column {
        /// What the column's bars are plotted against.
        let key: String
        /// What the axis prints under it, which only has to fit.
        let label: String
        let months: LibraryTotals.MonthColumn
    }

    private var thisYear: String { String(totals.year) }
    private var lastYear: String { String(totals.previousYear) }

    private var columns: [Column] {
        totals.monthColumns.compactMap { months in
            guard let named = months.thisYear ?? months.lastYear else { return nil }
            return Column(
                key: months.month.chartKey,
                label: totals.name(of: named, width: .narrow, locale: locale),
                months: months
            )
        }
    }

    private func bars(_ columns: [Column]) -> [Bar] {
        columns.flatMap { column in
            [
                column.months.lastYear.map { Bar(column: column.key, series: lastYear, month: $0) },
                column.months.thisYear.map { Bar(column: column.key, series: thisYear, month: $0) },
            ]
            .compactMap(\.self)
        }
    }

    var body: some View {
        let unit = TotalsFormat.chartUnit
        let drawn = columns
        let labels = Dictionary(drawn.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        Chart(bars(drawn)) { bar in
            BarMark(
                x: .value("Month", bar.column),
                y: .value("Distance", Self.value(bar.month.distanceMeters, in: unit)),
                width: .ratio(Self.barWidth)
            )
            .foregroundStyle(by: .value("Year", bar.series))
            .position(by: .value("Year", bar.series))
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius)
            )
            .accessibilityLabel("\(totals.name(of: bar.month, width: .wide, locale: locale)) \(bar.series)")
            .accessibilityValue(TotalsFormat.distance(bar.month.distanceMeters))
        }
        .chartForegroundStyleScale([lastYear: Color.gray.opacity(Self.lastYearOpacity), thisYear: Color.accentColor])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let label = labels[key] {
                        Text(label)
                    }
                }
            }
        }
        .chartYAxisLabel(unit.symbol)
        .frame(height: Self.height)
        .accessibilityIdentifier("library-month-chart")
    }

    private static func value(_ meters: Double, in unit: UnitLength) -> Double {
        Measurement(value: meters, unit: UnitLength.meters).converted(to: unit).value
    }
}

/// The three spellings this screen needs, each the one the rest of the app
/// uses for the same figure: a distance as the detail screen writes one, a
/// height through ``HikeFormat/elevation(_:locale:)``, and the chart's axis
/// in the unit the reader's roads are signed in.
private enum TotalsFormat {
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func height(_ meters: Double) -> String {
        HikeFormat.elevation(Measurement(value: meters, unit: UnitLength.meters))
    }

    static var chartUnit: UnitLength {
        switch Locale.autoupdatingCurrent.measurementSystem {
        case .us, .uk: .miles
        default: .kilometers
        }
    }
}
