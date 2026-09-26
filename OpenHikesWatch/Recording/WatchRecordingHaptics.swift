//
//  WatchRecordingHaptics.swift
//  OpenHikesWatch
//
//  What a walk feels like on a wrist.
//
//  This is the surface the haptic work exists for. A watch under a sleeve is
//  the one screen a hiker genuinely cannot look at, and the one where Pause
//  landing or not landing decides whether the next two kilometres are part of
//  the walk.
//
//  The projections below are the watch's half of the agreement the phone keeps
//  in ``RecordingHaptics``: both recorders answer the same table in
//  ``HapticMoment/walk(from:to:)``, so Pause feels like Pause whichever device
//  the hiker pressed it on. The table is tested on the macOS host by
//  `HapticWalkStateTests`, which is the only place a watch-side rule can be
//  asserted at all — there is no watch test bundle, and no watch simulator in
//  any gate. See *The watch app* in the instructions file.
//
//  A line per case and nothing else, for that same reason: everything here is
//  checked by the compiler's exhaustiveness and by reading, so everything that
//  could be got wrong lives in the shared table instead.
//

import OpenHikesShared

extension WatchRecorder.Phase {
    /// This recorder's phase in the terms the shared table speaks.
    var hapticWalkState: HapticWalkState {
        switch self {
        case .idle: .idle
        // Asking for location and Health, which can take as long as the hiker
        // takes to answer — the same news as the phone's `waitingForFix`.
        case .preparing: .preparing
        case .recording: .running
        case .paused: .paused
        // The watch stops on a screen showing the walk rather than returning
        // to an idle recorder, which is the whole reason the shared table has
        // a `finished` the phone never reaches.
        case .saved: .finished
        // Found at launch rather than arrived at, so there is no moment to
        // feel: the walk stopped with the last process, which nobody was
        // holding. What the hiker does about it is felt as that — a resume
        // as a start, a save as a finish.
        case .interrupted: .idle
        case .failed: .failed
        }
    }
}

extension WatchPhoneRecording.State {
    /// The *phone's* recording, as this watch is told about it.
    ///
    /// Drives the remote panel's haptics, and the distinction it carries is
    /// the point of putting one there: the buttons on that panel send a
    /// command and are disabled until the phone answers, so the tap itself
    /// says nothing worth feeling. What is worth feeling is the answer coming
    /// back — and it arrives here, as a state the phone published.
    var hapticWalkState: HapticWalkState {
        switch self {
        case .idle: .idle
        case .recording: .running
        case .paused: .paused
        }
    }
}
