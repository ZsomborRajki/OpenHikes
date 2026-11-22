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
        // The beginning and the middle. The endings are reported by whoever
        // ended the walk, which knows what kind of ending it was — see
        // ``WalkHaptics`` and ``WalkEndQuestion``.
        //
        // Scoped to the walked hike for the reason the `onChange` above is:
        // the session is one object and this view is on *every* hike's detail,
        // so two details alive in the stack at once would both answer the same
        // change. A phase can move without this screen being the one that
        // moved it — ``MovementReminderActions`` resumes a walk from a
        // notification — and that is the case where a hiker would feel the
        // same Resume twice.
        .sensoryFeedback(trigger: session.phase) { old, new in
            guard session.walkedHikeID == hike.id else { return nil }
            return hapticFeedback(forWalkPhase: old, to: new)?.feedback
        }
    }
}

/// The phase word, its dot, and the walk's clock.
///
/// The same arrangement as the recording header, for the same reasons: the
/// dot is a colour so the word beside it is spoken, and the clock is a 1 Hz
/// `TimelineView` that exists only while it is on screen. The clock reads
/// `session.activeSeconds()` — a function over ignored storage, so the tick
/// costs a `Text` and not an observation.
private struct WalkPhaseRow: View {
    let session: TrailWalkSession
    let phase: TrailWalkPhase
    let tint: Color

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(phase == .following ? tint : Color.secondary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(phase == .following ? String(localized: "Hike Active") : String(localized: "Hike Paused"))
                .font(.headline)
            Spacer()
            if phase == .following, scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    PhaseClock(readout: HikeFormat.duration(session.activeSeconds()))
                }
            } else {
                PhaseClock(readout: HikeFormat.duration(session.activeSeconds()))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("walk-phase")
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
