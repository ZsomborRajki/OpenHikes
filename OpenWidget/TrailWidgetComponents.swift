//
//  TrailWidgetComponents.swift
//  OpenWidget
//
//  The small, size-aware pieces the widget bodies are assembled from: the
//  per-family layout decisions, the row of stat chips, and the progress
//  hairline. Kept apart from TrailWidget.swift so each can be reasoned about
//  — and, for the layout, tested — without a rendered widget around it.
//

import OpenHikesShared
import SwiftUI
import WidgetKit

/// The size-dependent decisions the widget draws with, pulled out of the view
/// so they can be checked for every family without rendering one.
struct TrailWidgetLayout: Equatable {
    let routeLineWidth: Double
    let padding: Double
    /// How many stat chips fit on one line without crowding the status text
    /// under them. The chips are ordered most-useful-first, so truncating to
    /// this drops the least useful one — see
    /// ``SharedTrailSnapshot/metrics(limit:locale:)``.
    let metricLimit: Int

    init(family: WidgetFamily) {
        let isSmall = family == .systemSmall
        routeLineWidth = isSmall ? 3 : 4
        padding = isSmall ? 12 : 14
        // Two is every chip there is; the small family keeps only the first,
        // because a 155 pt square is mostly map and one number is a glance.
        metricLimit = isSmall ? 1 : 2
    }
}

/// A single stat chip: a glyph and a number, sized to sit in the widget's
/// bottom band without competing with the status line above it.
///
/// Both the glyph and the text are hidden from VoiceOver by the
/// `.accessibilityHidden(true)` below — every widget body that uses this
/// collapses to one accessibility element and speaks
/// ``TrailWidgetMetric/accessibilityPhrase`` instead, because a row of
/// unlabelled arrows read out one at a time says nothing.
struct TrailWidgetMetricRow: View {
    let metrics: [TrailWidgetMetric]
    /// Light-on-map, matching whatever the status line beside it decided.
    let onMap: Bool

    private enum Metrics {
        static let spacing: Double = 9
        static let glyphSpacing: Double = 2.5
        static let mapOpacity: Double = 0.85
    }

    var body: some View {
        if !metrics.isEmpty {
            HStack(spacing: Metrics.spacing) {
                ForEach(metrics) { metric in
                    HStack(spacing: Metrics.glyphSpacing) {
                        Image(systemName: metric.symbolName)
                            .imageScale(.small)
                        Text(metric.value)
                    }
                }
            }
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(
                onMap
                    ? AnyShapeStyle(Color.white.opacity(Metrics.mapOpacity))
                    : AnyShapeStyle(.secondary)
            )
            .accessibilityHidden(true)
        }
    }
}

/// The hairline under the stat line showing how much of the trail is behind
/// the walker.
///
/// Drawn only while there is a live fix — without one there is no progress to
/// report, and an empty track would read as "none of it done" rather than as
/// "not being walked".
struct TrailWidgetProgressBar: View {
    let fraction: Double
    let tint: Color
    let onMap: Bool

    private enum Metrics {
        static let height: Double = 2.5
        static let trackOpacity: Double = 0.35
        static let mapTrackOpacity: Double = 0.45
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        onMap
                            ? AnyShapeStyle(Color.white.opacity(Metrics.mapTrackOpacity))
                            : AnyShapeStyle(Color.secondary.opacity(Metrics.trackOpacity))
                    )
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: Metrics.height)
        .accessibilityHidden(true)
    }
}
