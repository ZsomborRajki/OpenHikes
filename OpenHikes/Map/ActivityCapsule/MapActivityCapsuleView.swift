//
//  MapActivityCapsuleView.swift
//  OpenHikes
//
//  What the map's activity capsule's status draws: the phase with its dot,
//  and under it the clock and, for a recording, the distance — see
//  ``MapActivityCapsule``.
//
//  SwiftUI inside the UIKit button that is the status — see
//  ``MapActivityCapsuleControlsView`` — for the clock: it ticks by itself, as
//  the Live Activity's does, through `Text(timerInterval:)`, so no body runs
//  for it and nothing ticks while the map is not drawn. Its own root, so what
//  it reads — the phase, the distance per fix — re-runs this and nothing on
//  the map or in the sheet. It says nothing to VoiceOver: MapKit walks only
//  the map's UIKit views, so the button around it does the saying.
//

import OpenHikesData
import SwiftUI

struct MapActivityCapsuleStatus: View {
    let capsule: MapActivityCapsule

    /// The last activity the capsule stood for, kept while it fades out so
    /// the fade has something to show.
    @State private var shown: MapActivityCapsule.Activity?

    var body: some View {
        Group {
            switch capsule.activity ?? shown {
            case .recording:
                RecordingCapsuleStatus(recorder: capsule.recorder)
            case let .walk(hikeID):
                WalkCapsuleStatus(walk: capsule.walk, hikeID: hikeID)
            case nil:
                EmptyView()
            }
        }
        .onChange(of: capsule.activity, initial: true) { _, activity in
            if let activity { shown = activity }
        }
        .accessibilityHidden(true)
    }
}

/// A recording's phase, clock and distance.
private struct RecordingCapsuleStatus: View {
    let recorder: HikeRecorder

    var body: some View {
        CapsuleStatusText(dot: recorder.phase.dotColor, title: recorder.phase.accessibilityTitle) {
            RecordingClockAndDistance(recorder: recorder)
        }
    }
}

/// A walk's phase and clock.
private struct WalkCapsuleStatus: View {
    let walk: TrailWalkSession
    let hikeID: UUID

    var body: some View {
        if let phase = walk.phase, walk.walkedHikeID == hikeID {
            CapsuleStatusText(
                dot: phase == .following ? .accentColor : .secondary,
                title: phase == .following ? String(localized: "Hike Active") : String(localized: "Hike Paused")
            ) {
                ActivityClock(elapsed: walk.activeSeconds(), isRunning: phase == .following)
            }
        }
    }
}

/// The phase over its figures.
private struct CapsuleStatusText<Figures: View>: View {
    let dot: Color
    let title: String
    @ViewBuilder let figures: () -> Figures

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dot)
                    .frame(width: CapsuleStatusMetrics.dotSize, height: CapsuleStatusMetrics.dotSize)
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            figures()
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(CapsuleStatusMetrics.minimumScale)
    }
}

/// The status's figures, apart from its view, because a generic type stores
/// no statics.
private enum CapsuleStatusMetrics {
    static let dotSize: CGFloat = 8
    /// How far the status may shrink before it gives up a character, so a
    /// long figure at a large text size still fits beside the tracking pill.
    static let minimumScale: CGFloat = 0.8
}
