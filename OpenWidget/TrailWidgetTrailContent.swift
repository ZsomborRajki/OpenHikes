//
//  TrailWidgetTrailContent.swift
//  OpenWidget
//
//  The Home Screen widget when a trail is selected and nothing is being
//  recorded. Split out of TrailWidget.swift, which holds the timeline provider
//  and the entry, so that the file describing what the widget *draws* is not
//  also the file describing when it is asked to.
//
//  Its opposite number, `RecordingWidgetContent`, stays nested inside
//  `TrailWidgetEntryView`: the two are chosen between in one `switch` there,
//  and the recording half is the shorter and the more tightly bound to that
//  choice — see the precedence rule on `TrailWidgetEntry.init`.
//

import OpenHikesShared
import SwiftUI
import WidgetKit

/// The selected trail: a map, the conditions and the trail's figures across
/// the top, and how far along it the hiker is across the bottom.
///
/// **Nothing is drawn in the middle.** The band of text that used to sit over
/// the lower third is gone, and what it said is now said by the two edges: the
/// percentage and the distance left were a sentence about a fraction, and a
/// bar is the same fact read at a glance. The map keeps the whole middle,
/// which on a 155 pt square is most of the widget.
struct TrailWidgetContent: View {
    let snapshot: SharedTrailSnapshot
    let basemaps: TrailBasemapSet?
    let weather: SharedWeatherReading?
    let family: WidgetFamily

    /// Text treatment for the light-on-map case, the companion to ``Scrim``:
    /// the scrim darkens the map, this keeps the glyphs legible on top of it.
    private enum MapTextStyle {
        static let shadowOpacity: Double = 0.35
    }

    /// Where the map is darkened, and by how much.
    ///
    /// Both ends now, which is the change: the text moved to the top of the
    /// widget and the bar to the bottom, so the undimmed middle is the part
    /// with the trail in it rather than the part with nothing in it. The two
    /// bands are deliberately unequal — the top carries a line of text and
    /// needs a real gradient under it, the bottom carries a 2.5 pt hairline
    /// and needs only enough to keep its track from vanishing over a snowfield.
    private enum Scrim {
        static let topOpacity: Double = 0.5
        static let topClearLocation: Double = 0.34
        static let bottomClearLocation: Double = 0.82
        static let bottomOpacity: Double = 0.32
    }

    private var layout: TrailWidgetLayout { TrailWidgetLayout(family: family) }
    private var tint: Color { Color(hex: snapshot.tintHex) ?? .green }
    private var metrics: [TrailWidgetMetric] { snapshot.metrics(limit: layout.metricLimit) }

    /// Whether a rendered map is actually behind the text, which is what
    /// decides between light-on-map and standard label colors.
    ///
    /// Any non-empty set resolves to *some* image for any size and
    /// appearance — that's what `image(forAspectRatio:appearance:)`'s
    /// fallback chain guarantees — so this needs no size math of its own. In
    /// the one case where it can be optimistic (the manifest survived but its
    /// files didn't, which the renderer actively prevents), the scrim below
    /// is drawn anyway and the text stays legible against it.
    private var hasMap: Bool { !(basemaps?.images.isEmpty ?? true) }

    /// Everything the one accessibility element says after the trail's name:
    /// how far along it the hiker is, then each chip in words, then the
    /// temperature. The glyphs themselves are hidden, so this is the only
    /// place any of the numbers are said — including the status line, which is
    /// no longer drawn anywhere.
    ///
    /// ``SharedTrailSnapshot/progressStatusText`` rather than `statusText`,
    /// because the length that line falls back to when there is no live fix
    /// is a chip now: the fallback would make the commonest state of a placed
    /// widget say its one number twice.
    private var accessibilityValue: String {
        TrailWidgetSpeech.value(
            status: snapshot.progressStatusText,
            metrics: snapshot.metricsAccessibilityText(limit: layout.metricLimit),
            weather: weather
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrailWidgetHeaderRow(metrics: metrics, onMap: hasMap) {
                if let weather {
                    TrailWidgetTemperature(text: weather.formatted(), onMap: hasMap)
                }
            }

            Spacer(minLength: 0)

            // Coverage while a walk is under way, position otherwise. It is
            // the whole of what the removed status line said, and it is on the
            // bottom edge because that is where a fraction of a journey reads
            // as a fraction rather than as decoration.
            if let fraction = snapshot.progressFraction {
                TrailWidgetProgressBar(fraction: fraction, tint: tint, onMap: hasMap)
            }
        }
        .shadow(color: .black.opacity(hasMap ? MapTextStyle.shadowOpacity : 0), radius: 2, y: 1)
        // One tap target, so one element — and the trail's name is spoken on
        // every family even though none of them draw it any more. The widget
        // shows the shape of the trail; VoiceOver has to be told which one.
        // See ``View/trailWidgetCanvas(padding:label:value:background:)``.
        .trailWidgetCanvas(
            padding: layout.padding,
            label: snapshot.title,
            value: accessibilityValue
        ) {
            TrailMapView(
                polyline: snapshot.polyline,
                basemaps: basemaps,
                tint: tint,
                liveFix: snapshot.liveFix?.coordinate,
                lineWidth: layout.routeLineWidth,
                imageData: TrailWidgetBasemapImages.data(named:)
            )

            if hasMap { scrim }
        }
    }

    /// Darkens only the two bands something is drawn in, so the middle of the
    /// map — where the trail is — keeps its own contrast.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(Scrim.topOpacity), location: 0),
                .init(color: .clear, location: Scrim.topClearLocation),
                .init(color: .clear, location: Scrim.bottomClearLocation),
                .init(color: .black.opacity(Scrim.bottomOpacity), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
