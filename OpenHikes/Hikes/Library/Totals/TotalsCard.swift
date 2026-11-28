//
//  TotalsCard.swift
//  OpenHikes
//
//  What every part of *Totals* is drawn from: the card, the small capitals
//  that name one, the heading over a group of them, and the figure itself.
//
//  The shapes are Health's and Fitness's, which is where a reader has
//  already learned to read a year of walking: a card to a measurement, its
//  name in small capitals beside a glyph, and the figure in rounded
//  numerals with its unit small beside it.
//
//  The card's fill is the one every other card in the map sheet has
//  (``View/placeCardGroup()``), for the reason that one gives: this is
//  content on a glass sheet, and a card of glass on glass reads as neither.
//

import SwiftUI

nonisolated enum TotalsMetrics {
    /// Between one group of cards and the next.
    static let sectionSpacing: CGFloat = 32
    /// Between a heading and its cards, and between two cards.
    static let cardSpacing: CGFloat = 12
    /// Between a card's edge and what it holds.
    static let cardPadding: CGFloat = 16
    /// Between a card's name and its figure.
    static let headingSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    /// The glyph column of a row, fixed so the rows' words line up.
    static let glyphWidth: CGFloat = 28
    static let rowSpacing: CGFloat = 12
    static let rowMinimumHeight: CGFloat = 52
    /// Above and below a row's words, which is what parts two rows once
    /// their text is taller than ``rowMinimumHeight``.
    static let rowPadding: CGFloat = 10
    /// How far a figure may shrink to stay on its line.
    static let minimumScale: CGFloat = 0.6

    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

extension View {
    /// Draws the screen's card behind this view.
    ///
    /// - Parameter vertical: Above and below the contents. Rows keep their
    ///   own height, and pass none.
    func totalsCard(vertical: CGFloat = TotalsMetrics.cardPadding) -> some View {
        padding(.horizontal, TotalsMetrics.cardPadding)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { TotalsMetrics.shape.fill(.quaternary) }
    }
}

/// The year, *All Time* or *Records* over its cards.
///
/// A `Text`, so a year is drawn as it is and every other heading is a key
/// the String Catalog lists; a `String` was drawn verbatim (#1028).
struct TotalsSectionHeading: View {
    let title: Text
    /// The year at the head of the screen, which is the screen's own title
    /// in all but name.
    var isProminent = false

    var body: some View {
        title
            .font(isProminent ? .largeTitle.bold() : .title2.bold())
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a card is about: a glyph in the tint beside small capitals.
struct TotalsCardHeading: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// What the card is about just now, after the title: the month under a
    /// finger on the chart. Words some other type has already resolved, so
    /// they are drawn as they are.
    var detail: String?

    /// The box every glyph is drawn in. Symbols differ in height, and a
    /// heading as tall as its own glyph put a tile's figure a point higher
    /// or lower than the figure in the tile beside it.
    @ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = 15

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: glyphSize, height: glyphSize)
                .accessibilityHidden(true)
            words
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(TotalsMetrics.minimumScale)
        }
        .font(.caption.weight(.semibold))
        // Spoken from the name, not from the small capitals drawn, which
        // VoiceOver would spell out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words)
        .accessibilityAddTraits(.isHeader)
    }

    /// The title, and the detail after it where there is one. The title is
    /// a key and the detail is not, so they are two texts side by side on
    /// one line, not one sentence put together.
    private var words: Text {
        guard let detail else { return Text(title) }
        return Text("\(Text(title)) · \(Text(verbatim: detail))")
    }
}

/// One figure: the number in rounded numerals, its unit smaller and quieter
/// beside it — see ``TotalsFigureRuns`` for where one ends and the other
/// begins.
struct TotalsFigure: View {
    enum Scale {
        /// The year's distance, at the head of the screen.
        case hero
        /// A card's own figure, and last year's beside the hero.
        case card
        /// A figure at the end of a row.
        case row
    }

    let figure: String
    var scale: Scale = .card
    /// Last year's, which stands beside this year's as context.
    var isQuiet = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Text(attributed)
            // Shrinking a figure to keep it on its line is fine at the
            // sizes it fits at. At an accessibility size the reader asked
            // for it bigger, so it wraps instead — as ``StatFigure`` does.
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : TotalsMetrics.minimumScale)
    }

    private var attributed: AttributedString {
        var text = AttributedString()
        for run in TotalsFigureRuns.runs(of: figure) {
            var piece = AttributedString(run.text)
            piece.font = run.isUnit ? unitFont : numberFont
            piece.foregroundColor = run.isUnit || isQuiet ? .secondary : .primary
            text += piece
        }
        return text
    }

    private var numberFont: Font {
        switch scale {
        case .hero: .system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit()
        case .card: .system(.title2, design: .rounded, weight: .semibold).monospacedDigit()
        case .row: .system(.body, design: .rounded, weight: .semibold).monospacedDigit()
        }
    }

    private var unitFont: Font {
        switch scale {
        case .hero: .system(.title3, design: .rounded, weight: .semibold)
        case .card: .system(.subheadline, design: .rounded, weight: .semibold)
        case .row: .system(.subheadline, design: .rounded, weight: .medium)
        }
    }
}

/// Rows in one card, with a hairline between each two that starts where the
/// rows' words do, as a list in Settings or Health draws its own.
struct TotalsRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            // Asked of the resolved subviews, so a row a caller leaves out
            // behind an `if` leaves no hairline behind either.
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Divider()
                            .padding(.leading, TotalsMetrics.glyphWidth + TotalsMetrics.rowSpacing)
                    }
                    row
                }
            }
        }
        .totalsCard(vertical: 0)
    }
}
