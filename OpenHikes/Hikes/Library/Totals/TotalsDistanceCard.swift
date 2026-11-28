//
//  TotalsDistanceCard.swift
//  OpenHikes
//
//  The year's distance, the first card of *Totals*: the figure, last year's
//  beside it, and the months under both.
//
//  It is laid out the way Health lays out a year of anything. The figure
//  stands over the chart, each year's with a dot in the color its bars are
//  drawn in, so the figures are the chart's legend as well. A finger on the
//  chart turns them into the month under it and dims every other month —
//  see ``TotalsDistanceReadout`` — and lifting it brings the year back.
//
//  The months are the hiker's calendar's, as many as the two years have —
//  see ``LibraryTotals`` — and each is named from its own span, so a Hebrew
//  leap year's seventh month reads Adar II and a common year's Adar.
//

import Charts
import SwiftUI

struct TotalsDistanceCard: View {
    private static let figureSpacing: CGFloat = 14

    let totals: LibraryTotals

    /// The month under the finger, by its ``LibraryTotals/Month/chartKey``.
    /// Kept here and not by the screen: every move of the finger writes it,
    /// and nothing outside this card reads it.
    @State private var selection: String?
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let readout = TotalsDistanceReadout(totals: totals, selectedKey: selection, locale: locale)
        VStack(alignment: .leading, spacing: Self.figureSpacing) {
            VStack(alignment: .leading, spacing: TotalsMetrics.headingSpacing) {
                TotalsCardHeading(title: "Distance", systemImage: TotalsGlyph.distance)
                figures {
                    TotalsYearFigure(side: readout.thisYear, series: .thisYear)
                    if let lastYear = readout.lastYear {
                        TotalsYearFigure(side: lastYear, series: .lastYear)
                    }
                }
            }
            TotalsMonthChart(totals: totals, selection: $selection)
        }
        .totalsCard()
    }

    /// Side by side, each in its own half so that neither moves as the
    /// other's digits change under a finger. One over the other at an
    /// accessibility text size, where half a card is not room for a figure.
    private var figures: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TotalsMetrics.headingSpacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TotalsMetrics.cardSpacing))
    }
}

/// Which year a figure or a bar is.
///
/// This year is the point and wears the tint; last year is context and is
/// gray. Neither is carried by color alone: each figure names its year, and
/// every bar speaks its month, its year and its distance.
enum TotalsSeries {
    case lastYear
    case thisYear

    private static let lastYearOpacity = 0.28

    /// Last year's gray is the text color thinned, not a gray of its own.
    /// The sheet is glass until it is pulled up, and over a pale map a dark
    /// sheet's glass is itself mid-gray: bars in `Color.gray` could not be
    /// told from the card they stood on.
    var color: Color {
        switch self {
        case .lastYear: .primary.opacity(Self.lastYearOpacity)
        case .thisYear: .accentColor
        }
    }
}

/// One year's figure over the chart: the distance, and under it the year
/// beside a dot in the color of its bars.
private struct TotalsYearFigure: View {
    private static let dotSize: CGFloat = 8
    private static let labelSpacing: CGFloat = 5

    let side: TotalsDistanceReadout.Side
    let series: TotalsSeries

    private var figure: String {
        // A dash for a month the year does not have, as every formatter in
        // the app writes a figure there is none of.
        side.meters.map { TotalsFormat.distance($0) } ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TotalsFigure(
                figure: figure,
                scale: series == .thisYear ? .hero : .card,
                isQuiet: series == .lastYear
            )
            HStack(spacing: Self.labelSpacing) {
                Circle()
                    .fill(series.color)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .accessibilityHidden(true)
                Text(verbatim: side.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A year and its distance are one fact, not two stops.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: side.label))
        .accessibilityValue(figure)
        .accessibilityIdentifier(series == .thisYear ? "library-totals-this-year" : "library-totals-last-year")
    }
}

/// Distance by month, this year beside last — the one comparison the screen
/// draws rather than states.
private struct TotalsMonthChart: View {
    /// A month's pair of bars fills this much of its column, and a month
    /// drawn alone a little less, so a year without a last year is not a row
    /// of slabs.
    private static let pairedWidth = 0.8
    private static let singleWidth = 0.56
    private static let cornerRadius: CGFloat = 3
    private static let height: CGFloat = 180
    /// Every month but the one under the finger.
    private static let unselectedOpacity = 0.3
    /// The axis under a chart with nothing in it, in the chart's unit: an
    /// axis from nothing to nothing draws no lines at all.
    private static let emptyAxisTop = 10.0
    private static let axisLineCount = 4

    let totals: LibraryTotals
    @Binding var selection: String?
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

    /// Last year's bar first, so it stands on the leading side of this
    /// year's, and none at all for a hiker with no last year.
    private func bars(_ columns: [Column]) -> [Bar] {
        let showsLastYear = totals.hasLastYear
        return columns.flatMap { column in
            let months = column.months
            return [
                showsLastYear ? months.lastYear.map { Bar(column: column.key, series: lastYear, month: $0) } : nil,
                months.thisYear.map { Bar(column: column.key, series: thisYear, month: $0) },
            ]
            .compactMap(\.self)
        }
    }

    var body: some View {
        let unit = TotalsFormat.chartUnit(in: locale)
        let drawn = columns
        let bars = bars(drawn)
        let labels = Dictionary(drawn.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        let top = bars.map { TotalsFormat.chartValue($0.month.distanceMeters, in: unit) }.max() ?? 0
        Chart(bars) { bar in
            BarMark(
                x: .value("Month", bar.column),
                y: .value("Distance", TotalsFormat.chartValue(bar.month.distanceMeters, in: unit)),
                width: .ratio(totals.hasLastYear ? Self.pairedWidth : Self.singleWidth)
            )
            .foregroundStyle(by: .value("Year", bar.series))
            .position(by: .value("Year", bar.series))
            .opacity(selection == nil || selection == bar.column ? 1 : Self.unselectedOpacity)
            .clipShape(
                UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius)
            )
            .accessibilityLabel("\(totals.name(of: bar.month, width: .wide, locale: locale)) \(bar.series)")
            .accessibilityValue(TotalsFormat.distance(bar.month.distanceMeters))
        }
        .chartForegroundStyleScale([lastYear: TotalsSeries.lastYear.color, thisYear: TotalsSeries.thisYear.color])
        // The figures over the chart name the two colors.
        .chartLegend(.hidden)
        .emptyChartAxis(top > 0 ? nil : Self.emptyAxisTop)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let label = labels[key] {
                        Text(label)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: Self.axisLineCount)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let distance = value.as(Double.self) {
                        Text(TotalsFormat.axisDistance(distance, in: unit, locale: locale))
                    }
                }
            }
        }
        .chartXSelection(value: $selection)
        .frame(height: Self.height)
        .accessibilityIdentifier("library-month-chart")
    }
}

private extension View {
    /// Gives a chart with nothing to plot an axis up to `top`. A chart with
    /// bars keeps the axis Swift Charts rounds for them.
    @ViewBuilder
    func emptyChartAxis(_ top: Double?) -> some View {
        if let top {
            chartYScale(domain: 0...top)
        } else {
            self
        }
    }
}
