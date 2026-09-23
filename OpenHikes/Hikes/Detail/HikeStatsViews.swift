//
//  HikeStatsViews.swift
//  OpenHikes
//
//  The place-card stats every screen about one walk draws — the hike detail,
//  the community preview, a walk's summary and the live recording — and the
//  hike detail's metadata rows.
//

import SwiftUI

nonisolated struct Stat: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let value: String
    /// Drawn in the card's strip rather than its list — see ``StatSummary``.
    let isHeadline: Bool

    init(_ label: String, _ value: String, headline: Bool = false) {
        self.label = label
        self.value = value
        isHeadline = headline
    }
}

/// A screen's numbers the way an Apple Maps place card draws a place's: the
/// few that answer "how big is it" in a strip across the top, and the rest in
/// one grouped list under a heading.
///
/// The hike detail, the community preview and a walk's summary all hand it
/// their ``Stat``s. The recording screen builds the same two halves out of
/// ``StatStrip`` and ``StatList`` itself, because its duration is a clock
/// rather than a value and has to tick inside the strip.
struct StatSummary: View {
    let stats: [Stat]

    var body: some View {
        let headline = stats.filter(\.isHeadline)
        let details = stats.filter { !$0.isHeadline }
        VStack(alignment: .leading, spacing: StatCardMetrics.sectionSpacing) {
            if !headline.isEmpty {
                StatStrip {
                    ForEach(headline) { stat in
                        StatFigure(label: stat.label, value: stat.value)
                    }
                }
            }
            if !details.isEmpty {
                StatList {
                    ForEach(details) { stat in
                        StatRow(label: stat.label, value: stat.value)
                    }
                }
            }
        }
    }
}

nonisolated enum StatCardMetrics {
    static let sectionSpacing: CGFloat = 20
    static let stripSpacing: CGFloat = 12
    static let listCornerRadius: CGFloat = 12
    static let listPadding: CGFloat = 16
    static let rowMinimumHeight: CGFloat = 44
    static let minimumScale: CGFloat = 0.7
}

/// The headline figures, side by side with a hairline between each — the
/// strip under a Maps place card's title.
///
/// It becomes a column at an accessibility text size: three figures across
/// an iPhone leave each about 100pt, which is not enough for a headline at
/// AX3 and above, and a number that has to shrink to fit is a number the
/// reader asked to be bigger.
struct StatStrip<Content: View>: View {
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    @ViewBuilder let content: Content

    var body: some View {
        layout {
            // Each figure after the first gets a divider ahead of it. Asked
            // of the resolved subviews, so a figure a caller leaves out behind
            // an `if` leaves no hairline behind either.
            Group(subviews: content) { figures in
                ForEach(figures) { figure in
                    if figure.id != figures.first?.id {
                        Divider()
                    }
                    figure
                }
            }
        }
        // What lets a vertical divider stretch to the height of the figures
        // beside it rather than to the height of the whole screen.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: StatCardMetrics.stripSpacing))
            : AnyLayout(HStackLayout(alignment: .top, spacing: StatCardMetrics.stripSpacing))
    }
}

/// One figure in a ``StatStrip``: a small caption over the number.
///
/// It stores the formatted value rather than anything it was formatted from,
/// which is what lets the recording screen's clock tick through it — see
/// ``PhaseClock`` for the freeze a stored reference causes.
struct StatFigure: View {
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(StatCardMetrics.minimumScale)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
                // Shrinking a number to keep three figures side by side is
                // fine at the sizes three fit at. At an accessibility size the
                // strip becomes a column, so the value is allowed to wrap and
                // grow instead of being squeezed.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(
                    dynamicTypeSize.isAccessibilitySize ? 1 : StatCardMetrics.minimumScale
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A caption and a number are one fact, not two stops — and the caption
        // is spoken from `label` rather than from the uppercased text above,
        // which VoiceOver would otherwise spell out ("A V G Speed").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// Every figure that is not a headline, as one grouped list with a hairline
/// between rows — the *Details* card of a Maps place card.
struct StatList<Content: View>: View {
    var title = "Statistics"
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Divider()
                        }
                        row
                    }
                }
            }
            .padding(.horizontal, StatCardMetrics.listPadding)
            .background {
                RoundedRectangle(cornerRadius: StatCardMetrics.listCornerRadius)
                    .fill(.quaternary)
            }
        }
    }
}

/// One row of a ``StatList``: the label leading, the value trailing.
///
/// At an accessibility text size the value goes under the label instead,
/// for the reason ``StatStrip`` becomes a column.
struct StatRow: View {
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    let label: String
    let value: String

    var body: some View {
        layout {
            Text(label)
                .foregroundStyle(.primary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .frame(
                    maxWidth: .infinity,
                    alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
                )
        }
        .font(.body)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: StatCardMetrics.rowMinimumHeight, alignment: .leading)
        // The whole row, not the line of text in it, is the element: without
        // a shape the combined element is framed by its text alone, which the
        // accessibility audit reports as a hit area too small to touch.
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    }
}

struct DetailRow: View {
    /// The glyph column's width, fixed so that every icon in a section hangs
    /// on the same line and the labels beside them line up — a column of
    /// symbols of different widths reads as a ragged edge rather than as a
    /// column.
    private static let iconWidth: CGFloat = 26
    private static let iconSpacing: CGFloat = 10

    let label: String
    let value: String
    /// An SF Symbol drawn ahead of the label, where there is one that says
    /// what the label says.
    ///
    /// Optional, and left `nil` on purpose more often than not: a row given a
    /// glyph because its neighbours have one is a glyph that means nothing,
    /// and the reader has to look at it to find that out. Rows without it are
    /// laid out exactly as they were before this existed.
    var systemImage: String?

    var body: some View {
        HStack(spacing: Self.iconSpacing) {
            if let systemImage {
                // Secondary rather than tinted or multicolour: these sit
                // beside a caption in that same weight, and a column of
                // coloured glyphs down a `List` competes with the reading
                // above it for the eye. The icon is also not announced —
                // `children: .ignore` below drops it, which is what we want,
                // since the label it duplicates is spoken already.
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconWidth)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
