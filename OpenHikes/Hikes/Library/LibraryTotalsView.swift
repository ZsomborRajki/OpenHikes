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

import Charts
import SwiftData
import SwiftUI

struct LibraryTotalsView: View {
    /// Opens one of the records, the way a row of the library does.
    var onOpenHike: (Hike) -> Void = { _ in /* no-op default */ }

    @Environment(\.modelContext)
    private var modelContext
    @State private var totals: LibraryTotals?

    var body: some View {
        ScrollView {
            if let totals {
                LibraryTotalsContent(totals: totals, onOpenHike: open)
                    .padding()
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
        .task {
            let read = await LibraryTotalsSweep.read(from: modelContext.container)
            let year = Calendar.autoupdatingCurrent.component(.year, from: .now)
            totals = LibraryTotals(hikes: read.hikes, walks: read.walks, year: year)
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
            Text(
                "Recordings and GPX files with times count as walked, and so does every walk along a saved trail. "
                    + "A trail you drew or saved counts once you walk it."
            )
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
            Stat("Walks", figures.outings.formatted()),
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
private struct LibraryMonthChart: View {
    /// Thin bars, the gap between a month's pair left by their width, and
    /// 4pt rounded tops.
    private static let barWidth = 0.8
    private static let cornerRadius: CGFloat = 4
    private static let height: CGFloat = 180
    private static let lastYearOpacity = 0.5
    /// What a bar is plotted against. The x axis is categorical, so its
    /// values have to be twelve distinct ones — the one-letter names are not:
    /// January, June and July would share a single "J" column.
    private static let monthKeys = Calendar.autoupdatingCurrent.shortMonthSymbols
    /// What the axis prints under each key, which only has to fit.
    private static let monthLabels = Calendar.autoupdatingCurrent.veryShortMonthSymbols

    let totals: LibraryTotals

    private struct Bar: Identifiable {
        let month: Int
        let series: String
        let meters: Double
        var id: String { "\(series)-\(month)" }
    }

    private var thisYear: String { String(totals.year) }
    private var lastYear: String { String(totals.year - 1) }

    private var bars: [Bar] {
        (0..<12).flatMap { month in
            [
                Bar(month: month, series: lastYear, meters: totals.monthsLastYear[month]),
                Bar(month: month, series: thisYear, meters: totals.monthsThisYear[month]),
            ]
        }
    }

    var body: some View {
        let unit = TotalsFormat.chartUnit
        Chart(bars) { bar in
            BarMark(
                x: .value("Month", Self.monthKeys[bar.month]),
                y: .value("Distance", Self.value(bar.meters, in: unit)),
                width: .ratio(Self.barWidth)
            )
            .foregroundStyle(by: .value("Year", bar.series))
            .position(by: .value("Year", bar.series))
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius)
            )
            .accessibilityLabel("\(Calendar.autoupdatingCurrent.monthSymbols[bar.month]) \(bar.series)")
            .accessibilityValue(TotalsFormat.distance(bar.meters))
        }
        .chartForegroundStyleScale([lastYear: Color.gray.opacity(Self.lastYearOpacity), thisYear: Color.accentColor])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let month = Self.monthKeys.firstIndex(of: key) {
                        Text(Self.monthLabels[month])
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
