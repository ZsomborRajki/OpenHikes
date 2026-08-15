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
    let label: String
    let value: String

    var body: some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
