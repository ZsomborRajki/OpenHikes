//
//  WalkControls.swift
//  OpenHikes
//
//  The walk under way, under the progress bar of the hike being walked: its
//  phase and clock.
//
//  Its controls are not here. Pause and Resume are the navigation bar's
//  ``WalkToggleButton``, and End is the bar's ``WalkEndButton`` beside it,
//  both on screen at every detent. End was a section's button here, under the
//  progress row, out of reach with the sheet down; the owner's "mini player"
//  (2026-11-20) put it beside Pause, on the bar and on the map's capsule —
//  see ``MapActivityCapsule``.
//
//  The controls exist only once there is a walk to control: opening a trail
//  is not walking it, and this draws nothing until the hiker moving along the
//  route or the navigation bar's Start has started one. On any *other* trail's detail
//  while a walk is under way, it draws the one-line notice naming the walk in
//  progress instead.
//
//  Reads the session's coarse properties — which hike, which phase — and
//  nothing that moves per fix, so a fix that extends coverage redraws the
//  progress row beside this and not this. `walk-phase` and `walk-controls`
//  are distinct from `recording-phase` on purpose, as are the button titles:
//  the recording's *Stop* must never be found by a test looking for the
//  walk's End, and vice versa.
//

import Foundation
import OpenHikesData
import OpenHikesShared
import SwiftUI

struct WalkControls: View {
    let hike: Hike
    let session: TrailWalkSession
    let onOpenWalk: (HikeWalk) -> Void

    var body: some View {
        Group {
            if session.walkedHikeID == hike.id, let phase = session.phase {
                WalkPhaseRow(session: session, phase: phase, tint: hike.tintOpaque)
            } else if session.walkedHikeID != nil {
                Text("A hike is in progress on \(session.walkedHikeTitle). End it there to hike this trail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("walk-notice")
            }
        }
        // A walk that reached the end on its own has no tap to push its
        // summary from; this is what does it. A tapped End opens its own
        // through ``ActivityEnding``, so only the automatic case is answered
        // here.
        .onChange(of: session.lastEndedWalk) { _, ended in
            guard let ended, ended.hikeID == hike.id, ended.endReason == .reachedEnd else { return }
            // The one ending nobody asked for, and so the one most worth
            // feeling: a hiker who walked the last of the route learns it
            // without taking the phone out.
            HapticMoment.walkSaved.play()
            onOpenWalk(ended)
        }
        // The beginning and the middle are felt at the root, wherever the
        // phase was moved from — see ``WalkPhaseHaptics``.
    }
}

/// The phase word, its dot, and the walk's clock.
///
/// The same arrangement as the recording header, for the same reasons: the
/// dot is a colour so the word beside it is spoken. The clock is the one the
/// bar above it and the map's capsule draw (``ActivityClock``), ticking by
/// itself with no body run for it, read off `session.activeSeconds()` when
/// the phase moves. It was a 1 Hz `TimelineView`, a pass of this row every
/// second of a walk.
private struct WalkPhaseRow: View {
    let session: TrailWalkSession
    let phase: TrailWalkPhase
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(phase == .following ? tint : Color.secondary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(phase == .following ? String(localized: "Hike Active") : String(localized: "Hike Paused"))
                .font(.headline)
            Spacer()
            ActivityClock(elapsed: session.activeSeconds(), isRunning: phase == .following)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("walk-phase")
    }
}

/// A trail's bar: Start, then Pause or Resume and End beside the walk's
/// phase and clock — see ``WalkToggleButton``, ``WalkEndButton`` and
/// ``WalkBarTitle``. Its own `ToolbarContent`, as the recording's
/// ``RecordingBar`` is, so the hike's screen gains a line rather than three
/// items.
struct WalkBar: ToolbarContent {
    let hike: Hike
    let profile: RouteProfile?
    let walkRevision: String?
    let session: TrailWalkSession

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            WalkBarTitle(hike: hike, session: session)
        }
        ToolbarItem(placement: .topBarTrailing) {
            WalkToggleButton(hike: hike, profile: profile, walkRevision: walkRevision, session: session)
        }
        ToolbarItem(placement: .topBarTrailing) {
            WalkEndButton(hike: hike, session: session)
        }
    }
}

/// The middle of the trail's bar: its name, or, while it is the one being
/// walked, the walk's phase and clock in its place, as the recording's bar
/// shows its own (``RecordingBar``). The bar is all a hiker sees at the
/// sheet's smallest detent, and Pause and End beside a walk nobody could see
/// the state of were controls without their readout.
///
/// A view of its own for the reason ``WalkToggleButton`` is one: a `.toolbar`
/// closure is inlined into the screen's body, which reads no walk.
struct WalkBarTitle: View {
    let hike: Hike
    let session: TrailWalkSession

    var body: some View {
        if session.walkedHikeID == hike.id, let phase = session.phase {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(phase == .following ? Color.accentColor : Color.secondary)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(phase == .following ? String(localized: "Hike Active") : String(localized: "Hike Paused"))
                        .font(.subheadline.weight(.semibold))
                }
                // Read when the phase moves, and ticking by itself between.
                ActivityClock(elapsed: session.activeSeconds(), isRunning: phase == .following)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("walk-bar-status")
        } else {
            // What the bar says without this item, in the system's words for
            // an inline title.
            Text(hike.displayTitle)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// End, in the walked trail's bar beside ``WalkToggleButton``, while that
/// trail is the one being walked.
///
/// It asks what the map's capsule asks, through the one object both hold —
/// see ``WalkEndQuestion``. Red, as a recording's Stop is, and found by
/// `walk-controls`, which End has always carried.
struct WalkEndButton: View {
    let hike: Hike
    let session: TrailWalkSession

    /// Optional so a preview without the model draws no End.
    @Environment(OpenHikesModel.self) private var appModel: OpenHikesModel?

    var body: some View {
        if session.walkedHikeID == hike.id, session.phase != nil, let question = appModel?.walkEnd {
            Button("End and Save Hike", systemImage: "stop.fill") { question.ask() }
                .prominentGlassButtonStyle()
                .tint(.red)
                .accessibilityIdentifier("walk-controls")
        }
    }
}
