//
//  TotalsTiles.swift
//  OpenHikes
//
//  The year's other four figures, a tile each under the distance: the climb,
//  the time on the move, the activities and the trails they were on. Each
//  says what last year's was under it, where there was a last year.
//
//  Two to a row, as Fitness lays out its summary, and one to a row at an
//  accessibility text size, where half the screen is not room for a figure.
//

import SwiftUI

/// The glyph each of the screen's measurements is drawn beside, in one
/// place so a measurement wears the same one in a tile and in a row.
///
/// Every name is in SF Symbols at the app's floor (*Deployment floor* in
/// the repository instructions): the compiler does not check one.
nonisolated enum TotalsGlyph {
    static let distance = "point.topleft.down.to.point.bottomright.curvepath"
    static let climb = "arrow.up.right"
    static let movingTime = "clock"
    static let activities = "figure.hiking"
    static let trails = "signpost.right"
    static let longest = "ruler"
    static let highest = "mountain.2"
    static let steepest = "angle"
}

struct TotalsYearTiles: View {
    let totals: LibraryTotals

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let year = totals.thisYear
        // `nil` in a hiker's first year: a tile then has nothing under its
        // figure, rather than a year of zeroes.
        let last = totals.hasLastYear ? totals.lastYear : nil
        let lastYear = String(totals.previousYear)
        let climb = TotalsTile(
            id: "climb",
            title: "Climb",
            systemImage: TotalsGlyph.climb,
            figure: .height(year.climbMeters),
            lastYear: last.map { .height($0.climbMeters) },
            lastYearLabel: lastYear
        )
        let movingTime = TotalsTile(
            id: "moving-time",
            title: "Moving Time",
            systemImage: TotalsGlyph.movingTime,
            figure: .duration(year.movingSeconds),
            lastYear: last.map { .duration($0.movingSeconds) },
            lastYearLabel: lastYear
        )
        let activities = TotalsTile(
            id: "activities",
            title: "Activities",
            systemImage: TotalsGlyph.activities,
            figure: .count(year.outings),
            lastYear: last.map { .count($0.outings) },
            lastYearLabel: lastYear
        )
        let trails = TotalsTile(
            id: "trails",
            title: "Trails",
            systemImage: TotalsGlyph.trails,
            figure: .count(year.trails),
            lastYear: last.map { .count($0.trails) },
            lastYearLabel: lastYear
        )
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: TotalsMetrics.cardSpacing) {
                climb
                movingTime
                activities
                trails
            }
        } else {
            Grid(horizontalSpacing: TotalsMetrics.cardSpacing, verticalSpacing: TotalsMetrics.cardSpacing) {
                GridRow {
                    climb
                    movingTime
                }
                GridRow {
                    activities
                    trails
                }
            }
        }
    }
}

/// One measurement of the year: its name, its figure, and last year's.
private struct TotalsTile: View {
    /// What a test finds the tile by: a key cannot be read back for one.
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    let figure: TotalsReading
    /// `nil` when nothing was walked last year.
    let lastYear: TotalsReading?
    let lastYearLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: TotalsMetrics.headingSpacing) {
            TotalsCardHeading(title: title, systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                TotalsFigure(figure: figure.drawn)
                if let lastYear {
                    Text(verbatim: "\(lastYearLabel) · \(lastYear.drawn)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(TotalsMetrics.minimumScale)
                }
            }
        }
        // As tall as the tile beside it, whichever holds more.
        .frame(maxHeight: .infinity, alignment: .top)
        .totalsCard()
        // One fact, spoken from the name and not from the small capitals
        // drawn, which VoiceOver would spell out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
        .accessibilityIdentifier("library-totals-tile-\(id)")
    }

    private var spokenValue: String {
        guard let lastYear else { return figure.spoken }
        return "\(figure.spoken), \(lastYearLabel): \(lastYear.spoken)"
    }
}
