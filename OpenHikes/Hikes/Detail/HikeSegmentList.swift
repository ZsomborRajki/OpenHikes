//
//  HikeSegmentList.swift
//  OpenHikes
//
//  The segments a hike's pauses cut it into, as a card of rows: each segment
//  with its own figures, and between two of them how long the stop was
//  (#1470).
//
//  One card for a saved hike and for the walk being recorded, so a walk reads
//  the same while it is recorded as after. A saved hike's segments are read
//  off its route with the rest of its figures (``RouteSegments``), and a
//  recording's are kept as it goes (``RecordingSegmentLedger``).
//

import Algorithms
import OpenHikesData
import SwiftUI

/// Nothing at all for a hike in one piece: one segment is the hike, which
/// the figures above already are.
struct HikeSegmentList: View {
    let segments: [RouteSegment]

    var body: some View {
        if segments.count > 1 {
            PlaceCardList(title: String(localized: "Segments")) {
                ForEach(segments.indexed(), id: \.index) { index, segment in
                    HikeSegmentRow(number: index + 1, figures: HikeSegmentFigures(segment))
                    if let stop = segment.stopSeconds {
                        StatRow(label: "Paused", value: HikeFormat.duration(stop))
                    }
                }
            }
        }
    }
}

/// One segment: its number and its length on a line, and its time, speed and
/// climb under it.
///
/// One element with one label and value, as every composite row is, spoken
/// from words: the drawn line is a middle dot, an arrow and abbreviations.
/// At an accessibility text size every figure goes under the one before it,
/// for the reason ``StatRow``'s value goes under its label.
private struct HikeSegmentRow: View {
    private static let climbSymbol = "arrow.up.right"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let number: Int
    let figures: HikeSegmentFigures

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            layout {
                Text("Segment \(number)")
                    .foregroundStyle(.primary)
                Text(figures.distance)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
                    )
            }
            .font(.body)
            layout {
                if let pace = figures.pace {
                    Text(pace)
                }
                if let climb = figures.climb {
                    Label(climb, systemImage: Self.climbSymbol)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: StatCardMetrics.rowMinimumHeight, alignment: .leading)
        // The whole row is the element, not the text in it — see ``StatRow``.
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Segment \(number)")
        .accessibilityValue(figures.spoken)
        .accessibilityIdentifier("hike-segment")
    }

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    }
}

/// Compared by what it draws, written out because the environment reader is
/// not a value — see ``StatFigure``'s `==`.
extension HikeSegmentRow: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.number == rhs.number && lhs.figures == rhs.figures
    }
}
