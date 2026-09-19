//
//  TrailFollowView.swift
//  OpenHikesWatch
//
//  One trail, drawn as a line with the hiker on it, and the four figures a
//  hiker actually looks at their wrist for.
//
//  ## Why a line and not a map
//
//  Because a basemap is hundreds of kilobytes per trail crossing a Bluetooth
//  link for a screen an inch wide, and a tile cache is not something that
//  belongs on a watch — the argument issue #509 made when it said the first
//  version would be figures and a trail-shaped line. ``TrailGlyphView`` in the
//  shared package already draws exactly that, fitted to whatever bounds it is
//  given, and is what the iOS widget falls back to for the same reason.
//
//  ## What each part may read
//
//  The glyph is handed a polyline that changes only when a new trail arrives.
//  The figures are in ``FollowFigures``, which is the only view that reads
//  ``WatchFollowState`` — so a fix redraws four `Text`s rather than this
//  screen.
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
                    TrailShape(trail: trail)
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

/// The trail's shape with the hiker's position on it.
///
/// Reads ``WatchFollowState`` for the dot, which is the one thing here that
/// moves. It is a separate view from ``FollowFigures`` so a fix redraws a
/// canvas *or* four labels rather than both plus their container.
private struct TrailShape: View {
    /// How tall the trail line is drawn.
    ///
    /// Enough to read a route's shape, and small enough that the figures
    /// under it are on the same screen without a scroll on a 40 mm watch —
    /// which is the whole point of showing both.
    private static let height = 74.0

    let trail: WatchTrailPackage

    @Environment(WatchModel.self)
    private var model

    var body: some View {
        TrailGlyphView(
            polyline: trail.polyline,
            tint: Color(hex: trail.tintHex) ?? .green,
            liveFix: liveFix,
            lineWidth: 2
        )
        .frame(height: Self.height)
        .accessibilityLabel("Shape of \(trail.title)")
    }

    /// Where to put the dot: the point on the *trail* the hiker was matched
    /// to, rather than the coordinate their receiver reported.
    ///
    /// The same choice `SharedTrailSnapshot.LiveFix` makes. A dot drawn at the
    /// raw fix sits beside the line whenever GPS is noisy, which on a line
    /// this thin reads as a hiker who has left the trail.
    ///
    /// Read straight off the match rather than worked back out of its distance
    /// along the trail. This screen cannot do the second one correctly: it
    /// would have to turn metres into a point on a line whose points are not
    /// evenly spaced, and the cumulative distances that make that exact belong
    /// to ``WatchRouteTracker``, which has already walked them to find this
    /// very point.
    private var liveFix: SharedTrailSnapshot.CodableCoordinate? {
        guard let position = model.follow.position, position.isOnTrail else { return nil }
        return position.trailCoordinate
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
