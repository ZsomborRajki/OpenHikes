//
//  TrailWidgetComponents.swift
//  OpenWidget
//
//  The small, size-aware pieces the widget bodies are assembled from: the
//  per-family layout decisions, the top line and the chips on it, the progress
//  hairline along the bottom, and the one sentence VoiceOver reads instead of
//  all of them. Kept apart from TrailWidget.swift so each can be reasoned
//  about — and, for the layout and the speech, tested — without a rendered
//  widget around it.
//

import OpenHikesShared
import SwiftUI
import WidgetKit

/// The size-dependent decisions the widget draws with, pulled out of the view
/// so they can be checked for every family without rendering one.
///
/// Home Screen families only. The accessory families draw no map, no chips and
/// no bar, so none of these three numbers has anything to decide for them —
/// see `TrailWidget.accessoryFamilies` and `TrailWidgetAccessories.swift`.
struct TrailWidgetLayout: Equatable {
    let routeLineWidth: Double
    let padding: Double
    /// How many stat chips fit across the top-right corner beside the
    /// temperature. The chips are ordered most-useful-first, so truncating to
    /// this drops the least useful one — see
    /// ``SharedTrailSnapshot/metrics(limit:locale:)``.
    let metricLimit: Int

    init(family: WidgetFamily) {
        let isSmall = family == .systemSmall
        routeLineWidth = isSmall ? 3 : 4
        padding = isSmall ? 12 : 14
        // Three is every chip there is, and two is the floor rather than one:
        // the climb and the length are what the top-right corner exists to
        // say, and a 155 pt square that gave up the length would be a widget
        // showing a trail without saying how long it is. The third — the
        // hiker's own height, or a recording's pace — is the one that has
        // somewhere else to be read.
        metricLimit = isSmall ? 2 : 3
    }
}

/// A single stat chip: a glyph and a number, sized to sit across the widget's
/// top-right corner without crowding the temperature opposite it.
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

/// The line across the top of the widget: whatever the caller puts on the
/// left, and the stat chips hard against the right edge.
///
/// A container rather than three fixed slots, because the two states put
/// different things on the left — a trail leads with the temperature, a
/// recording leads with the glyph that says whether it is still capturing —
/// and the only thing they genuinely share is this arrangement.
///
/// `firstTextBaseline`, so the temperature and the chips sit on one line
/// however the reader has sized their text. Centre alignment drifts them apart
/// as soon as the glyphs and the digits disagree about height, which at
/// caption2 they do.
struct TrailWidgetHeaderRow<Leading: View>: View {
    let metrics: [TrailWidgetMetric]
    /// Light-on-map, matching whatever the chips beside it decided.
    let onMap: Bool
    @ViewBuilder let leading: Leading

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HeaderMetrics.spacing) {
            leading
            Spacer(minLength: 0)
            TrailWidgetMetricRow(metrics: metrics, onMap: onMap)
        }
        .lineLimit(1)
        .minimumScaleFactor(HeaderMetrics.minimumScale)
    }
}

/// ``TrailWidgetHeaderRow``'s numbers, outside it because a generic type
/// cannot hold a `static let`.
private enum HeaderMetrics {
    static let spacing: Double = 8
    /// How far the row may shrink before it truncates. A small widget in a
    /// Fahrenheit region draws `-12°` beside two chips inside 131 points, and
    /// a reader on a larger Dynamic Type size draws all of it bigger; scaling
    /// is the failure that keeps every figure readable, where truncation drops
    /// one.
    static let minimumScale: Double = 0.75
}

/// The temperature in the widget's top-left corner.
///
/// No condition symbol beside it, deliberately. The app's badge draws one
/// because it has a capsule to itself and a hiker looking straight at it; here
/// the corner is four characters wide over a map, and a second glyph would
/// cost more legibility than a sun tells anyone who can see out of a window.
/// The number is the part that cannot be guessed.
struct TrailWidgetTemperature: View {
    let text: String
    let onMap: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(onMap ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .accessibilityHidden(true)
    }
}

/// The hairline along the bottom edge showing how much of the trail is behind
/// the hiker.
///
/// Drawn only while there is a live fix — without one there is no progress to
/// report, and an empty track would read as "none of it done" rather than as
/// "not being walked". A recording never draws one at all; see
/// `RecordingWidgetContent` for why it has no denominator to be a fraction of.
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

/// What the widget's single accessibility element says after the trail's name.
///
/// One place rather than one per state, because the widget is a glance and the
/// spoken version is the whole of it for a reader who cannot take that glance:
/// nothing on a Home Screen family is drawn *and* spoken any more — the status
/// line is gone from the screen, the chips are `accessibilityHidden`, and the
/// temperature has no words of its own. Two spellings of this would be two
/// widgets, and only one of them would get fixed.
///
/// The order is the order the facts are wanted in: where the walk stands, then
/// the figures behind that, then the conditions it is happening in. Anything
/// missing is omitted rather than announced, which is the same rule the chips
/// follow.
enum TrailWidgetSpeech {
    static func value(
        status: String,
        metrics: String,
        weather: SharedWeatherReading?
    ) -> String {
        [status, metrics, weather?.spoken()]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
