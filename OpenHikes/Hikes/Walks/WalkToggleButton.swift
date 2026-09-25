//
//  WalkToggleButton.swift
//  OpenHikes
//
//  Start, and then Pause, on the trailing edge of a hike detail's navigation
//  bar. In the bar rather than on the title row below it because the bar is
//  what is still on screen with the sheet squashed to its smallest detent,
//  which is where a hiker who has put the phone away and wants the map leaves
//  it — and from there the title row is out of reach.
//
//  A walk also starts on its own, on the first fix that matches a trail with
//  Follow This Trail on. This is the way to start one without waiting for
//  that: before the hiker is on the route, with following off, or straight
//  after an End. Once a walk is under way on this trail it is its Pause and
//  Resume — the only one there is. ``WalkControls`` further down carries the
//  phase, the clock and End and Save Hike, and no second Pause (#679).
//
//  Draws nothing while another trail holds the walk — ``WalkControls`` names
//  that one instead — nor on a recording's own draft, which never gets a
//  walk. Reads only the session's coarse properties, like ``WalkControls``,
//  and is its own view rather than a `.toolbar` closure's contents, so a
//  fix that extends coverage redraws neither this nor the detail around it.
//

import OpenHikesData
import OpenHikesShared
import SwiftUI

struct WalkToggleButton: View {
    let hike: Hike
    /// `nil` until the detail has built it; there is no route to walk until
    /// then, and ``TrailWalkSession/start(hike:profile:)`` needs its length.
    let profile: RouteProfile?
    let session: TrailWalkSession

    /// The phase a Pause or Resume asked for and the store refused.
    @State private var refusedPhase: TrailWalkPhase?

    var body: some View {
        Group {
            if session.walkedHikeID == hike.id, let phase = session.phase {
                Button(phase.toggleTitle, systemImage: phase.toggleSymbol) {
                    refusedPhase = session.togglePhase(from: phase)
                }
                .accessibilityIdentifier("walk-toggle")
            } else if session.walkedHikeID == nil, let profile, profile.totalDistanceMeters > 0,
                      session.canStartByHand(hike) {
                Button("Start Hike", systemImage: "play.fill") {
                    // The start's haptic is the phase moving, answered by
                    // ``WalkControls`` for this hike — not played here too.
                    session.start(hike: hike, profile: profile)
                }
                // Tinted glass in the bar, as the call to action it is; once
                // started the bar's own plain glass is enough.
                .prominentGlassButtonStyle()
                .accessibilityIdentifier("walk-toggle")
            }
        }
        .tint(hike.tintOpaque)
        .walkPhaseRefusalAlert($refusedPhase)
    }
}

extension TrailWalkPhase {
    /// The Pause or Resume a walk in this phase offers.
    var toggleTitle: LocalizedStringKey {
        switch self {
        case .following: "Pause Hike"
        case .paused: "Resume Hike"
        }
    }

    var toggleSymbol: String {
        switch self {
        case .following: "pause.fill"
        case .paused: "play.fill"
        }
    }
}

extension TrailWalkSession {
    /// Pauses a following walk or resumes a paused one — the tap behind the
    /// bar's ``WalkToggleButton``.
    ///
    /// - Returns: the phase the tap asked for when the store refused it, for
    ///   ``WalkPhaseRefusalAlert`` to say so; `nil` when it was written down.
    ///   A change that *was* written down says nothing here: the phase moved,
    ///   and ``WalkControls``' `sensoryFeedback` has already answered it.
    func togglePhase(from phase: TrailWalkPhase) -> TrailWalkPhase? {
        let changed = switch phase {
        case .following: pause()
        case .paused: resume()
        }
        guard !changed else { return nil }
        HapticMoment.walkFailed.play()
        return phase == .following ? .paused : .following
    }
}

/// Says so when a Pause or Resume was not written down.
///
/// Without it a refused Pause is a button that does nothing: the walk is
/// deliberately left following, because that is what the sidecar still says,
/// and the row above goes on reading Hike Active.
private struct WalkPhaseRefusalAlert: ViewModifier {
    @Binding var refused: TrailWalkPhase?

    func body(content: Content) -> some View {
        content.alert(
            "Could not change this hike",
            isPresented: Binding(get: { refused != nil }, set: { if !$0 { refused = nil } })
        ) {
            Button("OK", role: .cancel) { /* no-op */ }
        } message: {
            Text(
                refused == .paused
                    ? "Pausing it could not be saved, so the hike is still under way. Try pausing it again."
                    : "Resuming it could not be saved, so the hike is still paused. Try resuming it again."
            )
        }
    }
}

extension View {
    func walkPhaseRefusalAlert(_ refused: Binding<TrailWalkPhase?>) -> some View {
        modifier(WalkPhaseRefusalAlert(refused: refused))
    }
}
