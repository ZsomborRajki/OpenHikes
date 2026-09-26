//
//  TrailDetailView.swift
//  OpenHikesWatch
//
//  The four figures a hiker looks at their wrist for, and the button that
//  records the trail they are standing on.
//
//  Presented as a sheet from ``TrailMapScreen``, which is what a trail opens
//  as. This is the answer to "how much is left"; the map is the answer to
//  "which way now", and that is the one asked at a fork with a watch already
//  raised — so it gets the screen and this gets a button.
//
//  ## What each part may read
//
//  ``FollowFigures`` is the only view here that reads ``WatchFollowState``, so
//  a fix redraws four `Text`s rather than this sheet and the button under it.
//  The trail is handed in already resolved: nothing can open this without one,
//  because the map screen is where a hiker waits for the package to arrive.
//

import OpenHikesShared
import SwiftUI

struct TrailDetailView: View {
    let trail: WatchTrailPackage

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                FollowFigures(trail: trail)
                RecordAlongTrailButton()
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(trail.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The figures, and the only view that reads the live position.
private struct FollowFigures: View {
    let trail: WatchTrailPackage

    @Environment(WatchModel.self)
    private var model

    var body: some View {
        VStack(spacing: 6) {
            if let position = model.follow.position {
                ProgressView(value: position.fractionComplete)
                    .tint(Color(hex: trail.tintHex) ?? .green)
                    .accessibilityLabel("Progress along the trail")
                    .accessibilityValue("\(Int((position.fractionComplete * 100).rounded())) percent")
                Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        WatchFigure(title: "Left", value: WidgetFormat.length(meters: position.remainingMeters))
                        WatchFigure(title: "Done", value: "\(Int((position.fractionComplete * 100).rounded()))%")
                    }
                    GridRow {
                        WatchFigure(title: "Trail", value: elevationText(position))
                        WatchFigure(title: "Off", value: offTrailText(position))
                    }
                }
            } else {
                Text("Finding you on the trail…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(WidgetFormat.length(meters: trail.totalDistanceMeters) + " in all")
                .font(.caption2)
                .foregroundStyle(.secondary)
            climb
        }
    }

    /// The trail's own climb and descent, which the phone measures over the
    /// *whole* route before it decimates it — see `WatchTrailPackaging`.
    ///
    /// Beneath the grid rather than in it, because every figure up there moves
    /// with the hiker and these two do not: they are facts about the trail,
    /// the same for the whole walk, and they are what a hiker checks before
    /// setting off rather than while walking.
    ///
    /// Both or neither: the phone fills them from one pass that reports
    /// nothing at all for a route whose points carry no heights, and an
    /// imported GPX without elevation is the ordinary way that happens. A
    /// "0 m" drawn for it would read as flat rather than as unknown.
    @ViewBuilder private var climb: some View {
        if let gain = trail.elevationGainMeters, let loss = trail.elevationLossMeters {
            let up = WidgetFormat.elevation(meters: gain)
            let down = WidgetFormat.elevation(meters: loss)
            Text("\(Image(systemName: "arrow.up.right")) \(up)   \(Image(systemName: "arrow.down.right")) \(down)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                // Spelled out, because two arrows and two numbers read aloud
                // as four figures with nothing to tell them apart.
                .accessibilityLabel("\(up) of climb, \(down) of descent")
        }
    }

    private func elevationText(_ position: WatchRouteTracker.Position) -> String {
        guard let elevation = position.trailElevationMeters else { return "—" }
        return WidgetFormat.elevation(meters: elevation)
    }

    /// Said for the off-trail case too, which is the reading that matters
    /// most: a hiker who has walked off a trail is better served by "180 m"
    /// than by a screen that quietly stops saying anything.
    private func offTrailText(_ position: WatchRouteTracker.Position) -> String {
        position.isOnTrail ? "On" : WidgetFormat.length(meters: position.offRouteMeters)
    }
}

/// Starts a recording named after the trail, from the trail's own screen.
///
/// Here as well as on the Record tab because this is where a hiker is standing
/// when they decide to: they have opened the trail, they are at the trailhead,
/// and the walk they are about to record is this one.
private struct RecordAlongTrailButton: View {
    @Environment(WatchModel.self)
    private var model

    var body: some View {
        switch model.recorder.phase {
        case .idle, .failed, .saved:
            if model.isPhoneRecording {
                // Said rather than offered. ``WatchModel/startRecording(alongTrail:)``
                // refuses while the phone is recording — two hikes for one
                // walk is the failure a hiker finds afterwards in their
                // library — so a button here was one that could be pressed
                // and did nothing at all. The Record screen is where the
                // phone's own recording can be seen and driven, which is the
                // same rule it applies to its own Start.
                Label("Your iPhone is recording", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await model.startRecording(alongTrail: true) }
                } label: {
                    Label("Record This Hike", systemImage: "record.circle")
                }
                .tint(.red)
            }
        case .unsaved:
            // Said rather than offered, like the phone's recording above: a
            // start from here would begin over a walk the watch has not
            // written yet, and ``WatchRecorder/start(trailHikeID:title:)``
            // refuses it. The Record screen is where it can be retried.
            Label("Last walk not saved", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        case .preparing:
            ProgressView()
        case .interrupted:
            // Not a second Start. The interrupted walk is on the Record
            // screen, and a recording begun here would be begun over it.
            Label("A walk was interrupted — see Record", systemImage: "exclamationmark.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .recording, .paused:
            Label("Recording", systemImage: "record.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
