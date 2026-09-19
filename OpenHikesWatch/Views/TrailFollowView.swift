//
//  TrailFollowView.swift
//  OpenHikesWatch
//
//  One trail on a map with the hiker on it, and the four figures a hiker
//  actually looks at their wrist for.
//
//  ## Why a map now, when this shipped a bare line
//
//  The line was chosen against shipping a *rendered basemap over the link* —
//  hundreds of kilobytes per trail across Bluetooth, which is what the iOS
//  widget pays for its image. MapKit on watchOS fetches its own tiles and
//  costs the link nothing, so that argument never applied to it; see
//  ``TrailMapPanel``, which also explains what a watch out of range still
//  draws. `TrailGlyphView` stays where it was always right: the widget.
//
//  ## What each part may read
//
//  ``TrailMapPanel`` and ``FollowFigures`` each read ``WatchFollowState`` in
//  their own body, so a fix redraws a map and four `Text`s rather than this
//  screen around them.
//

import OpenHikesShared
import SwiftUI

struct TrailFollowView: View {
    let hikeID: UUID
    let name: String

    @Environment(WatchModel.self)
    private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let trail = model.trail, trail.hikeID == hikeID, trail.isDrawable {
                    // The map is a link rather than a picture: it is the one
                    // thing on this screen a hiker wants bigger, and the panel
                    // itself cannot take a gesture without stealing the
                    // scroll. See `TrailMapScreen`.
                    NavigationLink {
                        TrailMapScreen(trail: trail)
                    } label: {
                        TrailMapPanel(trail: trail)
                    }
                    .buttonStyle(.plain)
                    FollowFigures(trail: trail)
                    RecordAlongTrailButton()
                } else {
                    waiting
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.selectTrail(hikeID)
            model.startFollowing()
        }
        .onDisappear {
            // Only when nothing is recording. A recording owns the feed and
            // outlives this screen — which is the whole point of it.
            if !model.recorder.phase.isActive { model.stopFollowing() }
        }
    }

    private var waiting: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text(
                model.link.isReachable
                    ? "Fetching this trail from your iPhone…"
                    : "Waiting for your iPhone to come back in range…"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
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
            Button {
                Task { await model.startRecording(alongTrail: true) }
            } label: {
                Label("Record This Hike", systemImage: "record.circle")
            }
            .tint(.red)
        case .preparing:
            ProgressView()
        case .recording, .paused:
            Label("Recording", systemImage: "record.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}
