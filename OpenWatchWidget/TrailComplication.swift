//
//  TrailComplication.swift
//  OpenWatchWidget
//
//  Same push/event-driven timeline pattern as the iOS widget (see
//  OpenWidget/TrailWidget.swift): reads whatever the watch-local SharedStore
//  currently holds — kept fresh by WatchConnectivityBridge, never by this
//  extension doing any work of its own — and reloads only when told to.
//
//  .accessoryCorner is deliberately not supported here: its curved-label
//  API needs visual tuning I can't verify without a real device/Simulator
//  session, so it's left out rather than guessed at.
//

import WidgetKit
import SwiftUI
import OpenTrailsShared

struct TrailComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedTrailSnapshot?
}

struct TrailComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrailComplicationEntry {
        TrailComplicationEntry(date: .now, snapshot: Self.placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrailComplicationEntry) -> Void) {
        let snapshot = context.isPreview ? Self.placeholderSnapshot : SharedStore.load()
        completion(TrailComplicationEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrailComplicationEntry>) -> Void) {
        let entry = TrailComplicationEntry(date: .now, snapshot: SharedStore.load())
        let safetyNet = Calendar.current.date(byAdding: .hour, value: 6, to: .now) ?? .now.addingTimeInterval(6 * 3600)
        completion(Timeline(entries: [entry], policy: .after(safetyNet)))
    }

    fileprivate static let placeholderSnapshot = SharedTrailSnapshot(
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

struct TrailComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrailComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        default:
            rectangular
        }
    }

    @ViewBuilder
    private var circular: some View {
        if let snapshot = entry.snapshot {
            Gauge(value: snapshot.fractionComplete ?? 0) {
                Image(systemName: "figure.hiking")
            } currentValueLabel: {
                if let fraction = snapshot.fractionComplete {
                    Text("\(Int((fraction * 100).rounded()))")
                } else {
                    Image(systemName: "figure.hiking")
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            Image(systemName: "figure.hiking")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                TrailGlyphView(
                    polyline: snapshot.polyline,
                    liveFix: snapshot.liveFix?.coordinate,
                    tint: Color(hex: snapshot.tintHex) ?? .green,
                    lineWidth: 2
                )
                .frame(maxHeight: .infinity)
                Text(snapshot.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text("Select a trail in OpenTrails")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var inline: some View {
        if let snapshot = entry.snapshot {
            Text("\(snapshot.title): \(snapshot.statusText)")
        } else {
            Text("No trail selected")
        }
    }
}

struct TrailComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrailWidgetKind.id, provider: TrailComplicationProvider()) { entry in
            TrailComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Trail")
        .description("Shows your progress along the selected trail.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#Preview(as: .accessoryRectangular) {
    TrailComplication()
} timeline: {
    TrailComplicationEntry(date: .now, snapshot: TrailComplicationProvider.placeholderSnapshot)
    TrailComplicationEntry(date: .now, snapshot: nil)
}
