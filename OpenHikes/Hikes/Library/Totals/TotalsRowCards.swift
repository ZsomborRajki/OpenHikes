//
//  TotalsRowCards.swift
//  OpenHikes
//
//  The two cards of *Totals* that are rows: everything walked in all, and
//  the records.
//
//  *All Time* is the year's five measurements again without a chart or a
//  year to stand beside, so it is five rows, each led by the glyph its tile
//  wears. A record is a hike, and its row opens it, the way a row of the
//  library does: a badge, the record and the hike it belongs to, the figure
//  and a chevron.
//

import SwiftUI

/// Every measurement of everything walked, a row each.
struct TotalsAllTimeCard: View {
    let figures: LibraryTotals.Figures

    var body: some View {
        TotalsRows {
            row("Distance", id: "distance", systemImage: TotalsGlyph.distance, .distance(figures.distanceMeters))
            row("Climb", id: "climb", systemImage: TotalsGlyph.climb, .height(figures.climbMeters))
            row("Moving Time", id: "moving-time", systemImage: TotalsGlyph.movingTime, .duration(figures.movingSeconds))
            row("Activities", id: "activities", systemImage: TotalsGlyph.activities, .count(figures.outings))
            row("Trails", id: "trails", systemImage: TotalsGlyph.trails, .count(figures.trails))
        }
    }

    /// `title` is a key, so the String Catalog lists it. A key cannot be
    /// lowercased into the identifier, so that is passed beside it.
    private func row(
        _ title: LocalizedStringKey,
        id: String,
        systemImage: String,
        _ figure: TotalsReading
    ) -> some View {
        TotalsFigureRow(title: title, systemImage: systemImage, figure: figure)
            .accessibilityIdentifier("library-totals-all-time-\(id)")
    }
}

/// A measurement's glyph and name, with its figure at the trailing edge, or
/// under the name at an accessibility text size.
private struct TotalsFigureRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let figure: TotalsReading

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: TotalsMetrics.rowSpacing) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .totalsRowGlyph()
            layout {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TotalsFigure(figure: figure.drawn, scale: .row)
            }
        }
        .padding(.vertical, TotalsMetrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: TotalsMetrics.rowMinimumHeight, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(figure.spoken)
    }

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TotalsMetrics.rowSpacing))
    }
}

/// The longest, the highest and the steepest hike, each a row that opens
/// it. A record nothing holds has no row — see ``LibraryTotals`` for what
/// can hold one.
struct TotalsRecordsCard: View {
    let totals: LibraryTotals
    /// Opens the record's hike.
    let onOpenHike: (UUID) -> Void

    var body: some View {
        TotalsRows {
            record("Longest", id: "longest", systemImage: TotalsGlyph.longest, totals.longest) { candidate in
                TotalsFormat.distance(candidate.distanceMeters)
            }
            record("Highest", id: "highest", systemImage: TotalsGlyph.highest, totals.highest) { candidate in
                TotalsFormat.height(candidate.highestMeters ?? 0)
            }
            record("Steepest", id: "steepest", systemImage: TotalsGlyph.steepest, totals.steepest) { candidate in
                String(localized: "\(TotalsFormat.height(candidate.climbMeters ?? 0)) up")
            }
        }
    }

    /// `label` is a key, so the String Catalog lists it. A key cannot be
    /// lowercased into the identifier, so that is passed beside it.
    @ViewBuilder
    private func record(
        _ label: LocalizedStringKey,
        id: String,
        systemImage: String,
        _ candidate: LibraryRecordCandidate?,
        figure: (LibraryRecordCandidate) -> String
    ) -> some View {
        if let candidate {
            Button { onOpenHike(candidate.hikeID) } label: {
                TotalsRecordRow(
                    label: label,
                    systemImage: systemImage,
                    hikeTitle: candidate.title,
                    figure: figure(candidate)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library-record-\(id)")
        }
    }
}

/// One record: a badge, what the record is over the hike that holds it, the
/// figure, and the chevron of a row that goes somewhere.
private struct TotalsRecordRow: View {
    private static let badgeSize: CGFloat = 28
    private static let badgeOpacity = 0.16

    let label: LocalizedStringKey
    let systemImage: String
    let hikeTitle: String
    let figure: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: TotalsMetrics.rowSpacing) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: Self.badgeSize, height: Self.badgeSize)
                .background(.tint.opacity(Self.badgeOpacity), in: .circle)
                // The badge is one size, so its glyph is too.
                .totalsRowGlyph(largest: .large)
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    Text(verbatim: hikeTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TotalsFigure(figure: figure, scale: .row)
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, TotalsMetrics.rowPadding)
        .frame(maxWidth: .infinity, minHeight: TotalsMetrics.rowMinimumHeight, alignment: .leading)
        // The whole row, not the text in it, is what is tapped.
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    /// A `String`, so it is spoken as it is and not looked up as a key.
    private var spokenValue: String { "\(hikeTitle) · \(figure)" }

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: TotalsMetrics.rowSpacing))
    }
}

private extension View {
    /// A row's glyph, in the column every row's glyph stands in.
    ///
    /// The column is as wide at every text size, so the glyph stops growing
    /// where it would outgrow it: it is decoration, and the words beside it
    /// are what the reader asked to be bigger.
    func totalsRowGlyph(largest: DynamicTypeSize = .xxxLarge) -> some View {
        dynamicTypeSize(...largest)
            .frame(width: TotalsMetrics.glyphWidth)
            .accessibilityHidden(true)
    }
}
