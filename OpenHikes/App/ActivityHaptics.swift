//
//  ActivityHaptics.swift
//  OpenHikes
//
//  What a recording and a walk feel like, on whatever screen is up.
//
//  The map's capsule pauses, resumes and stops either from any screen — see
//  ``MapActivityCapsule`` — so the haptics cannot live on the activity's own
//  screen, where they were while only its bar could move the phase. They
//  stand at the root, in `OpenHikesView`'s background, once each.
//

import SwiftUI

/// The recording's and the walk's phase haptics, drawing nothing. Each reads
/// its own phase in its own body — see ``RecordingHaptics`` and
/// ``WalkPhaseHaptics`` — so neither this nor the root reads one.
struct ActivityHaptics: View {
    let recorder: HikeRecorder
    let walk: TrailWalkSession

    var body: some View {
        RecordingHaptics(recorder: recorder)
        WalkPhaseHaptics(session: walk)
    }
}
