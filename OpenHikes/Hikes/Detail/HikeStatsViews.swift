//
//  HikeStatsViews.swift
//  OpenHikes
//
//  Small building-block views used by HikeDetailView's stats grid and metadata
//  section; StatTile is also used by the recording screen's live stats.
//

import SwiftUI

nonisolated struct Stat: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

struct StatTile: View {
    private static let minimumScale: CGFloat = 0.7

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)
                // Shrinking a number to keep two tiles side by side is fine at
                // the sizes two tiles fit at. At an accessibility size the
                // grid drops to one column (see ``StatGrid``), so the value is
                // allowed to wrap and grow instead of being squeezed.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(
                    dynamicTypeSize.isAccessibilitySize ? 1 : Self.minimumScale
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
        }
        // A caption and a number are one fact, not two stops — and the caption
        // is spoken from `label` rather than from the uppercased text above,
        // which VoiceOver would otherwise spell out ("A V G Speed").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// The two-column layout both the hike detail and the recording screen lay
/// their ``StatTile``s out in.
///
/// It becomes a single column at an accessibility text size: two tiles across
/// an iPhone leave each one about 160pt wide, which is not enough for a
/// headline at AX3 and above, and a number that has to shrink to fit is a
/// number the reader asked to be bigger.
struct StatGrid<Content: View>: View {
    private static var spacing: CGFloat { 12 }

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: columns, spacing: Self.spacing) {
            content
        }
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
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
