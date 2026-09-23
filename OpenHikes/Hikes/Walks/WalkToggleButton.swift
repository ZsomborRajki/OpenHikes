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
//  Resume, beside the fuller ``WalkControls`` group further down, which is
//  still where End lives.
//
//  Draws nothing while another trail holds the walk — ``WalkControls`` names
//  that one instead — nor on a recording's own draft, which never gets a
//  walk. Reads only the session's coarse properties, like ``WalkControls``,
//  and is its own view rather than a `.toolbar` closure's contents, so a
//  fix that extends coverage redraws neither this nor the detail around it.
//

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
