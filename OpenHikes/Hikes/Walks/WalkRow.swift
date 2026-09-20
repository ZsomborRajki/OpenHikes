//
//  WalkRow.swift
//  OpenHikes
//
//  One walk in a trail's History: when, how much, and how it ended.
//

import SwiftUI

struct WalkRow: View {
    private static let ringWidth: CGFloat = 4
    /// The unwalked part of the coverage ring.
    ///
    /// It is the half of the ring that says what the walked part is a
    /// fraction *of*, so a track that disappears into the sheet leaves an arc
    /// with nothing to read it against — see ``Color/contentSurface``.
    private static let ringTrackOpacity = 0.3

    let walk: HikeWalk
    let tint: Color

    var body: some View {
        TrailListRow(
            title: Self.date(walk.startedAt),
            subtitle: subtitle,
            // The drawn line is shorthand — a percent sign, a middle dot and
            // an abbreviated duration — so the row is spoken from words
            // instead. The trail's title is the navigation title above and is
            // not repeated. See ``TrailListRow``.
            spokenSubtitle: spokenSubtitle,
            identifier: "walk-row"
        ) {
            ring
        }
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
    }

    private var percent: Int { Int((walk.coveredFraction * 100).rounded()) }

    private var subtitle: String {
        "\(percent)% walked · \(HikeFormat.duration(walk.activeSeconds)) · \(Self.outcome(walk.endReason))"
    }

    private var spokenSubtitle: String {
        let duration = HikeFormat.spokenDuration(walk.activeSeconds)
        return "\(percent) percent walked, \(duration), \(Self.outcome(walk.endReason).lowercased())"
    }

    /// The word for how a walk ended. A reason this build does not know reads
    /// as a plain end rather than as a blank.
    static func outcome(_ reason: TrailWalkEndReason?) -> String {
        switch reason {
        case .reachedEnd: "Completed"
        case .abandoned: "Left open"
        case .recorded: "Recorded"
        case .ended, nil: "Ended"
        }
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
