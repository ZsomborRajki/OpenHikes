//
//  TrailWidget.swift
//  OpenWidget
//
//  Shows the shape of whichever trail is currently selected in OpenTrails,
//  plus your last-known position along it. Never reads location itself —
//  it only ever displays whatever the main app most recently wrote to
//  SharedStore (see OpenTrailsShared), refreshed by the app calling
//  WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id).
//

import WidgetKit
import SwiftUI
import OpenTrailsShared

struct TrailWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedTrailSnapshot?
    /// The map images the app rendered for `snapshot`'s trail, if any — see
    /// `TrailBasemapRenderer` in the app target. Only the manifest is carried
    /// here; the image itself is read at render time by whichever view ends
    /// up needing it, so an entry never holds a decoded bitmap.
    var basemaps: TrailBasemapSet?

    /// Pairs a stored snapshot with its basemaps, which are only ever valid
    /// for the hike they were rendered for.
    init(date: Date, snapshot: SharedTrailSnapshot?) {
        self.date = date
        self.snapshot = snapshot
        self.basemaps = snapshot.flatMap { SharedStore.loadBasemapSet(for: $0.hikeID) }
    }

    /// Where tapping the widget goes. Absent in the empty state, where there
    /// is no trail to open and a plain launch is the right outcome.
    var deepLinkURL: URL? {
        snapshot.flatMap { TrailWidgetDeepLink.url(hikeID: $0.hikeID) }
    }
}

struct TrailWidgetProvider: TimelineProvider {
    /// How far ahead the timeline schedules its self-healing reload.
    ///
    /// Freshness is driven by the app's explicit `reloadTimelines` calls
    /// (selection changes, the foreground follow loop, and background
    /// significant-location-change events) — not by a fixed schedule. This
    /// distant `.after` is only a safety net in case a reload call is ever
    /// missed (e.g. the app is killed mid-write); it costs at most a couple of
    /// extra reloads a day against the system's daily budget.
    static let safetyNetHours = 6

    func placeholder(in context: Context) -> TrailWidgetEntry {
        Self.placeholderEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (TrailWidgetEntry) -> Void) {
        completion(context.isPreview ? Self.placeholderEntry() : Self.currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrailWidgetEntry>) -> Void) {
        completion(Self.currentTimeline())
    }

    // The three below take the date rather than reading the clock, and are
    // separate from the protocol methods above, because `TimelineProviderContext`
    // has no initializer available outside WidgetKit — so this is the widest
    // surface a test can reach at all.

    /// Whatever the app most recently wrote, with its basemaps if it has any.
    static func currentEntry(date: Date = .now) -> TrailWidgetEntry {
        TrailWidgetEntry(date: date, snapshot: SharedStore.load())
    }

    static func placeholderEntry(date: Date = .now) -> TrailWidgetEntry {
        TrailWidgetEntry(date: date, snapshot: placeholderSnapshot)
    }

    static func currentTimeline(date: Date = .now) -> Timeline<TrailWidgetEntry> {
        Timeline(entries: [currentEntry(date: date)], policy: .after(nextReload(after: date)))
    }

    static func nextReload(after date: Date) -> Date {
        Calendar.current.date(byAdding: .hour, value: safetyNetHours, to: date)
            ?? date.addingTimeInterval(Double(safetyNetHours) * 3600)
    }

    /// A generic loop shown in the widget gallery / as a redacted placeholder
    /// — never real trail data.
    static let placeholderSnapshot = SharedTrailSnapshot(
        hikeID: UUID(),
        title: "Trail",
        tintHex: "#34C759",
        totalDistanceMeters: 4200,
        polyline: [
            .init(latitude: 37.3349, longitude: -122.0140),
            .init(latitude: 37.3372, longitude: -122.0098),
            .init(latitude: 37.3358, longitude: -122.0050),
            .init(latitude: 37.3400, longitude: -122.0020),
            .init(latitude: 37.3440, longitude: -122.0060)
        ]
    )
}

/// The size-dependent decisions the widget draws with, pulled out of the view
/// so they can be checked for every family without rendering one.
struct TrailWidgetLayout: Equatable {
    /// The small family has no room for a title above the stat line.
    let showsTitle: Bool
    let routeLineWidth: Double
    let padding: Double

    init(family: WidgetFamily) {
        let isSmall = family == .systemSmall
        showsTitle = !isSmall
        routeLineWidth = isSmall ? 3 : 4
        padding = isSmall ? 12 : 14
    }
}

struct TrailWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrailWidgetEntry

    var body: some View {
        content
            // Whole-widget tap target: opens the app straight to this trail's
            // detail view.
            .widgetURL(entry.deepLinkURL)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            TrailWidgetContent(snapshot: snapshot, basemaps: entry.basemaps, family: family)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "figure.hiking")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a trail in OpenTrails")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrailWidgetContent: View {
    let snapshot: SharedTrailSnapshot
    let basemaps: TrailBasemapSet?
    let family: WidgetFamily

    private var layout: TrailWidgetLayout { TrailWidgetLayout(family: family) }
    private var tint: Color { Color(hex: snapshot.tintHex) ?? .green }
    private var showsTitle: Bool { layout.showsTitle }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(hasMap ? Color.white : .primary)
            }

            Spacer(minLength: 0)

            statLine
        }
        .shadow(color: .black.opacity(hasMap ? 0.35 : 0), radius: 2, y: 1)
        .padding(layout.padding)
        // The map is the widget's background rather than a subview, so it
        // runs edge to edge under the text and the system rounds it to the
        // widget's own corner radius. It also means the system can drop it
        // wherever container backgrounds don't belong — StandBy, tinted
        // Home Screens — and the text still stands on its own.
        .containerBackground(for: .widget) {
            ZStack {
                // Shows through only until the first render lands, or if one
                // never does: the fallback glyph needs something behind it.
                Rectangle().fill(.fill.tertiary)

                TrailMapView(
                    polyline: snapshot.polyline,
                    liveFix: snapshot.liveFix?.coordinate,
                    basemaps: basemaps,
                    tint: tint,
                    lineWidth: layout.routeLineWidth
                )

                if hasMap { scrim }
            }
        }
    }

    /// Darkens only the bands the text occupies, so the middle of the map —
    /// where the trail is — keeps its own contrast. The top band is dropped
    /// entirely on sizes with no title to darken it for.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(showsTitle ? 0.45 : 0), location: 0),
                .init(color: .clear, location: showsTitle ? 0.3 : 0),
                .init(color: .clear, location: 0.6),
                .init(color: .black.opacity(0.55), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var statLine: some View {
        HStack {
            Text(snapshot.statusText)
                .font(family == .systemSmall ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(hasMap ? Color.white : .secondary)
            Spacer()
            // Only where there's width for it without crowding the status.
            if showsTitle, let timestamp = snapshot.liveFix?.timestamp {
                Text(timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(hasMap ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
            }
        }
    }
}

struct TrailWidget: Widget {
    /// Every size this widget offers. Named rather than inlined so a test can
    /// check that each one has a layout to draw with.
    static let supportedFamilies: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrailWidgetKind.id, provider: TrailWidgetProvider()) { entry in
            TrailWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Trail")
        .description("Shows the shape of your selected trail and your last-known position along it.")
        .supportedFamilies(Self.supportedFamilies)
    }
}

#Preview(as: .systemSmall) {
    TrailWidget()
} timeline: {
    TrailWidgetEntry(date: .now, snapshot: TrailWidgetProvider.placeholderSnapshot)
    TrailWidgetEntry(date: .now, snapshot: nil)
}
