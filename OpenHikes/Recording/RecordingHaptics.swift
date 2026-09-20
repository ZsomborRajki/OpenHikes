//
//  RecordingHaptics.swift
//  OpenHikes
//
//  What a recording feels like in a pocket.
//
//  Every moment the recording screen has to offer is a phase transition —
//  started, first fix, paused, resumed, kept, thrown away, failed — so the
//  whole of the walk tier is one `sensoryFeedback` on `HikeRecorder.phase`,
//  and no button on the screen is touched. Which is the point: a haptic
//  written into a button's action fires when the *button* was tapped, and the
//  news a hiker is waiting for is whether the recorder agreed. Stop opens a
//  naming alert and saves some seconds later; Start waits on a fix that may
//  not come. The phase is where those two answers arrive.
//
//  It is a `View` and not a modifier on `RecordingView` for the reason
//  ``RecordingPhotoPins`` is one, and the instructions file states it as a
//  rule under *Render isolation, in practice*: a `sensoryFeedback` modifier is
//  inlined into the body that declares it, so writing it on the screen would
//  register `phase` as an input of the screen. That happens to be harmless
//  today — the screen already reads `phase` for its header — and it is exactly
//  the kind of harmless that stops being true when somebody later moves the
//  header into a subview and cannot work out why the screen still redraws.
//  The boundary costs a zero-sized `Color.clear` and says what it is.
//
//  Nothing here is gated on a setting. See ``HapticMoment`` for why the
//  system's own Haptics switch is the whole answer.
//

import OpenHikesShared
import SwiftUI

extension HikeRecorder.Phase {
    /// This recorder's phase in the terms ``HapticMoment/walk(from:to:)``
    /// speaks — the shared table the watch's recorder answers to as well.
    ///
    /// Lossy on purpose. `waitingForFix` is the same news as the watch's
    /// `preparing`: asked for, not yet drawing. What the table needs to tell
    /// apart is kept from thrown away, and `saving` is what does that.
    var hapticWalkState: HapticWalkState {
        switch self {
        case .idle: .idle
        case .recovering: .recovering
        case .waitingForFix: .preparing
        case .recording: .running
        case .paused: .paused
        case .reviewing: .reviewing
        case .saving: .saving
        case .failed: .failed
        }
    }
}

/// Plays the walk's moments, and draws nothing.
///
/// Sized zero and placed in a `.background`, so it is in the hierarchy — which
/// is what a `sensoryFeedback` needs to fire — without being on the screen.
struct RecordingHaptics: View {
    let recorder: HikeRecorder

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .sensoryFeedback(trigger: recorder.phase) { old, new in
                HapticMoment.walk(
                    from: old.hapticWalkState,
                    to: new.hapticWalkState
                )?.feedback
            }
    }
}
