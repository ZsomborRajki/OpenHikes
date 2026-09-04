//
//  WalkRow.swift
//  OpenHikes
//
//  One walk in a trail's History: when, how much, and how it ended.
//

import SwiftUI

struct WalkRow: View {
    private static let ringSize: CGFloat = 38
    private static let ringWidth: CGFloat = 4
    private static let ringTrackOpacity = 0.2

    let walk: HikeWalk
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            ring

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.date(walk.startedAt))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        // One element, the way `HikeRow` is: the label leads with the date,
        // and the value carries the percentage and how the walk ended. The
        // trail's title is the navigation title above and is not repeated.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.date(walk.startedAt))
        .accessibilityValue(spokenValue)
        .accessibilityIdentifier("walk-row")
    }

    /// The coverage as a ring, so a row reads at a glance as half, most, or
    /// all of the trail.
    private var ring: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(Self.ringTrackOpacity), lineWidth: Self.ringWidth)
            Circle()
                .trim(from: 0, to: walk.coveredFraction)
                .stroke(tint, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
        .accessibilityHidden(true)
    }

    private var percent: Int { Int((walk.coveredFraction * 100).rounded()) }

    private var subtitle: String {
        "\(percent)% walked · \(HikeFormat.duration(walk.activeSeconds)) · \(Self.outcome(walk.endReason))"
    }

    private var spokenValue: String {
        let duration = HikeFormat.spokenDuration(walk.activeSeconds)
        return "\(percent) percent walked, \(duration), \(Self.outcome(walk.endReason).lowercased())"
    }

    /// The word for how a walk ended. A reason this build does not know reads
    /// as a plain end rather than as a blank.
    static func outcome(_ reason: TrailWalkEndReason?) -> String {
        switch reason {
        case .reachedEnd: "Completed"
        case .abandoned: "Left open"
        case .ended, nil: "Ended"
        }
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
