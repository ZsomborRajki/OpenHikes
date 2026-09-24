//
//  WatchGlanceWidget.swift
//  OpenHikesWatchWidgets
//
//  The watch's complication and Smart Stack widget: a way into the app that
//  does not need the app opened first, and — while the watch's own recording
//  runs — its distance and clock.
//
//  It draws ``WatchGlanceDisplay`` and decides nothing: what to show, when a
//  glance is too old to believe and when to redraw all live in the shared
//  package, where they are tested — see *The watch app* in the repository
//  instructions. A running clock is a `Text(timerInterval:)`, which the
//  system ticks without an entry a second; the app asks for a reload when
//  something the hiker would notice has changed, and ``WatchGlanceTimeline``
//  adds the one entry nobody would ask for — the moment a glance goes stale.
//

import OpenHikesShared
import SwiftUI
import WidgetKit

@main
struct OpenHikesWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchGlanceWidget()
    }
}

struct WatchGlanceEntry: TimelineEntry {
    let date: Date
    let display: WatchGlanceDisplay
}

struct WatchGlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchGlanceEntry {
        WatchGlanceEntry(date: .now, display: .idle)
    }

    // `@escaping` because the protocol's requirement says so, though both
    // answers are already in memory and are handed back at once.
    // swiftlint:disable:next unneeded_escaping
    func getSnapshot(in context: Context, completion: @escaping (WatchGlanceEntry) -> Void) {
        completion(Self.entries()[0])
    }

    // swiftlint:disable:next unneeded_escaping
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchGlanceEntry>) -> Void) {
        // `.never`: every change worth drawing is a reload the app asks for,
        // and going stale is already an entry of its own.
        completion(Timeline(entries: Self.entries(), policy: .never))
    }

    /// Never empty: the first is always what to draw now.
    private static func entries() -> [WatchGlanceEntry] {
        WatchGlanceTimeline.entries(for: WatchGlanceStore.load(), now: .now).map { entry in
            WatchGlanceEntry(date: entry.date, display: entry.display)
        }
    }
}

struct WatchGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchGlanceStore.widgetKind, provider: WatchGlanceProvider()) { entry in
            WatchGlanceView(display: entry.display)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("OpenHikes")
        .description("Start a recording, or see the one under way.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

struct WatchGlanceView: View {
    @Environment(\.widgetFamily)
    private var family

    /// How far a distance may shrink to fit the circular face before it is
    /// cut instead.
    private static let distanceMinimumScale = 0.6

    let display: WatchGlanceDisplay

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .accessoryCorner: corner
        default: circular
        }
    }

    private var glyph: some View {
        // Decorative: every face that shows it says in words what it means.
        Image(systemName: symbol)
            .widgetAccentable()
            .accessibilityHidden(true)
    }

    /// The glyph as the whole of a face, which is when it has to be spoken.
    private var appGlyph: some View {
        Image(systemName: symbol)
            .widgetAccentable()
            .accessibilityLabel("OpenHikes")
    }

    private var symbol: String {
        switch display {
        case .idle: "figure.hiking"
        case .recording: "record.circle"
        case .paused: "pause.circle"
        }
    }

    @ViewBuilder private var circular: some View {
        switch display {
        case .idle:
            appGlyph.font(.title2)
        case let .recording(distance, _), let .paused(distance, _):
            VStack(spacing: 0) {
                glyph.font(.caption)
                Text(distance).font(.caption2).minimumScaleFactor(Self.distanceMinimumScale)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }

    @ViewBuilder private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: symbol).font(.headline).widgetAccentable()
            switch display {
            case .idle:
                Text("Tap to record a hike").foregroundStyle(.secondary)
            case let .recording(distance, timerStart):
                Text(distance)
                Text(timerInterval: timerStart...Date.distantFuture, countsDown: false)
                    .foregroundStyle(.secondary)
            case let .paused(distance, elapsed):
                Text(distance)
                Text(elapsed).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var inline: some View {
        switch display {
        case .idle: Label("OpenHikes", systemImage: symbol)
        case let .recording(distance, _), let .paused(distance, _): Label(distance, systemImage: symbol)
        }
    }

    @ViewBuilder private var corner: some View {
        switch display {
        case .idle:
            appGlyph.font(.title3)
        case let .recording(distance, _), let .paused(distance, _):
            glyph.font(.title3)
                .widgetLabel { Text(distance) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private var title: String {
        switch display {
        case .idle: "OpenHikes"
        case .recording: "Recording"
        case .paused: "Paused"
        }
    }

    private var label: String {
        switch display {
        case .idle: "OpenHikes"
        case let .recording(distance, _): "Recording, \(distance)"
        case let .paused(distance, _): "Paused, \(distance)"
        }
    }
}
