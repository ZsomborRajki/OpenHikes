//
//  TotalsHighlightCard.swift
//  OpenHikes
//
//  *Highlights*: this year so far against last year by this day, said in a
//  sentence and drawn as two bars — see ``TotalsDistanceHighlight`` for
//  what is compared and when there is nothing to say.
//
//  The card is Health's highlight: the sentence first, in the weight of a
//  finding, then each year's figure over a bar as long as its share of the
//  longer year. The bars are the colors the month chart draws the two years
//  in, and each is named for its year beside its figure and not inside the
//  bar, where the name would be small text on a tint.
//

import SwiftUI

struct TotalsHighlightCard: View {
    private static let barSpacing: CGFloat = 14

    let highlight: TotalsDistanceHighlight
    /// The two years as the rest of the screen names them —
    /// ``LibraryTotals/yearName``.
    let yearName: String
    let previousYearName: String

    var body: some View {
        VStack(alignment: .leading, spacing: Self.barSpacing) {
            VStack(alignment: .leading, spacing: TotalsMetrics.headingSpacing) {
                TotalsCardHeading(title: "Distance", systemImage: TotalsGlyph.distance)
                sentence
                    .font(.headline)
                    // The whole sentence, on as many lines as it takes.
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library-totals-highlight")
            }
            TotalsHighlightBar(
                figure: TotalsFormat.distance(highlight.thisYearMeters),
                label: yearName,
                share: highlight.thisYearShare,
                series: .thisYear
            )
            TotalsHighlightBar(
                figure: TotalsFormat.distance(highlight.lastYearMeters),
                label: previousYearName,
                share: highlight.lastYearShare,
                series: .lastYear
            )
        }
        .totalsCard()
    }

    /// Three sentences and not one with a word swapped in: "farther" and
    /// "not as far" are not one word's two forms in most of the languages
    /// the app speaks.
    private var sentence: Text {
        switch highlight.standing {
        case .ahead: Text("So far this year, you’ve hiked farther than by this day last year.")
        case .behind: Text("So far this year, you haven’t hiked as far as by this day last year.")
        case .level: Text("So far this year, you’ve hiked about as far as by this day last year.")
        }
    }
}

/// One year of the highlight: its figure, its name, and a bar as long as
/// its share of the longer year's.
private struct TotalsHighlightBar: View {
    private static let height: CGFloat = 14
    private static let cornerRadius: CGFloat = 4
    private static let figureSpacing: CGFloat = 6
    /// A year with nothing in it by this day still has a bar to be seen.
    private static let minimumWidth: CGFloat = 6

    let figure: String
    let label: String
    /// From 0 to 1 of the card's width.
    let share: Double
    let series: TotalsSeries

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Self.figureSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: TotalsMetrics.rowSpacing) {
                TotalsFigure(figure: figure)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(series.color(in: colorScheme))
                    .frame(width: max(Self.minimumWidth, proxy.size.width * share))
            }
            .frame(height: Self.height)
            .accessibilityHidden(true)
        }
        // A year and its distance are one fact, not two stops, and the
        // bar's length is the figure again.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(figure)
        .accessibilityIdentifier(
            series == .thisYear ? "library-totals-highlight-this-year" : "library-totals-highlight-last-year"
        )
    }
}
