//
//  TrailWidgetAccessories.swift
//  OpenWidget
//
//  The Lock Screen half of the trail widget: the circular, rectangular and
//  inline accessory families.
//
//  They share the widget's data and its deep link but none of its drawing.
//  There is no map — an accessory family renders in a vibrant, largely
//  monochrome mode where a rendered basemap becomes a grey smear — and no
//  stat chips, because a glyph-and-number pair that is legible at 155 pt is
//  not legible at 40. So `TrailWidgetLayout`, which describes the map inset
//  and the chip budget, does not apply here and is deliberately not consulted;
//  see `TrailWidget.systemFamilies`.
//
//  Each of the three collapses to one accessibility element, the way every
//  system family does: the whole widget is one tap target, so it is read as
//  one thing. The circular family in particular draws nothing but a glyph or
//  a ring, both of which are decoration — without a label spoken over the top
//  of them it would be a Lock Screen widget that says nothing at all.
//

import OpenHikesShared
import SwiftUI
import WidgetKit

/// What the accessory families say, in the order the widget's own precedence
/// rule requires.
///
/// **A live recording outranks the selected trail**, exactly as it does in
/// ``TrailWidgetEntry/init(date:snapshot:recordingSnapshot:)``, on the Lock
/// Screen panel and in the Control Center button. That initializer already
/// clears `snapshot` whenever a recording is present, so asking about the
/// recording first is belt-and-braces rather than load-bearing — but it is
/// written in the same order as every other surface, because a reader who
/// finds one of the four asking the trail first has to go and prove that it
/// cannot matter.
enum TrailWidgetAccessorySubject: Equatable {
    // Alphabetical, as `sorted_enum_cases` requires; `init` below is where
    // the precedence order lives.
    case empty
    case recording(SharedRecordingSnapshot)
    case trail(SharedTrailSnapshot)

    init(entry: TrailWidgetEntry) {
        if let recording = entry.recordingSnapshot {
            self = .recording(recording)
        } else if let snapshot = entry.snapshot {
            self = .trail(snapshot)
        } else {
            self = .empty
        }
    }

    /// What the family draws first and what VoiceOver reads first — the two
    /// are one property so a Lock Screen widget cannot show one trail's name
    /// and speak another's.
    var title: String {
        switch self {
        case .empty: "OpenHikes"
        case let .recording(recording): recording.title
        case let .trail(trail): trail.title
        }
    }

    var status: String {
        switch self {
        case .empty: "Select a trail"
        case let .recording(recording): recording.statusText
        case let .trail(trail): trail.statusText
        }
    }
}

/// The round Lock Screen slot: a progress ring while there is progress to
/// report, otherwise the app's glyph on the standard accessory backing.
struct AccessoryCircularContent: View {
    let entry: TrailWidgetEntry

    private var subject: TrailWidgetAccessorySubject { TrailWidgetAccessorySubject(entry: entry) }

    /// Only a followed trail has a fraction — a recording is a track being
    /// laid down, with no known total to be a fraction of.
    private var progress: Double? {
        guard case let .trail(trail) = subject else { return nil }
        return trail.progressFraction
    }

    var body: some View {
        dial
            // One tap target, so one element. Everything inside is decoration
            // and hides itself; this is the only thing VoiceOver reads.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(subject.title)
            .accessibilityValue(subject.status)
    }

    @ViewBuilder private var dial: some View {
        if case let .trail(trail) = subject, let progress {
            Gauge(value: progress) {
                Image(systemName: "figure.hiking")
                    .accessibilityHidden(true)
            } currentValueLabel: {
                Text(progress, format: .percent.precision(.fractionLength(0)))
            }
            // Explicit rather than inherited: `DefaultGaugeStyle` resolves to
            // a *linear* bar on iOS, which in a 40 pt circle is a hairline
            // across the middle of an otherwise empty slot.
            .gaugeStyle(.accessoryCircular)
            .tint(Color(hex: trail.tintHex) ?? .green)
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: glyphName)
                    .font(.title2)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A paused recording reads as paused by shape rather than by colour, the
    /// same choice `RecordingWidgetContent.stateGlyph` makes — an accessory
    /// family is rendered near-monochrome, so colour says nothing here at all.
    private var glyphName: String {
        if case let .recording(recording) = subject, !recording.isCapturingFixes {
            return "pause.fill"
        }
        return "figure.hiking"
    }
}

/// The wide Lock Screen slot: the name, what is happening, and the same
/// progress hairline the Home Screen families draw under their chips.
struct AccessoryRectangularContent: View {
    let entry: TrailWidgetEntry

    private var subject: TrailWidgetAccessorySubject { TrailWidgetAccessorySubject(entry: entry) }

    private var progress: Double? {
        guard case let .trail(trail) = subject else { return nil }
        return trail.progressFraction
    }

    private var tint: Color {
        guard case let .trail(trail) = subject else { return .green }
        return Color(hex: trail.tintHex) ?? .green
    }

    private enum Metrics {
        static let spacing: Double = 2
        static let horizontalPadding: Double = 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text(subject.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(subject.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let progress {
                TrailWidgetProgressBar(fraction: progress, tint: tint, onMap: false)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subject.title)
        .accessibilityValue(subject.status)
    }
}

/// The one-line slot above the clock. WidgetKit flattens this family to a
/// single string, so there is nothing to lay out and nothing to hide from
/// VoiceOver — the text it draws is the text it speaks.
struct AccessoryInlineContent: View {
    let entry: TrailWidgetEntry

    var body: some View {
        let subject = TrailWidgetAccessorySubject(entry: entry)
        Text("\(subject.title) · \(subject.status)")
            .lineLimit(1)
    }
}
