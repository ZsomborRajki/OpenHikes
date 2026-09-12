//
//  HikeRecorder+Reminders.swift
//  OpenHikes
//
//  The recorder's half of the movement reminders: what a pause does with the
//  sensors, and what a launch does with a pause it found in the journal.
//
//  Kept apart from `HikeRecorder+Helpers.swift` because it is a subject rather
//  than a utility — every decision here is about the one question
//  ``MovementReminderController`` answers, and the recorder's own state
//  machine is untouched by all of it. See the *Energy policies in force*
//  section of the repository instructions for what a pause is now allowed to
//  spend.
//

import CoreLocation
import Foundation

extension HikeRecorder {
    /// Everything off *except* whatever can still notice the hiker setting
    /// off again, for a recording that is paused.
    ///
    /// Called from the journal queue once the pause is durably written, so the
    /// hiker cannot lose a pause boundary to a crash between the two — which
    /// is what this shares with ``stopLocationSensors()`` and the whole of
    /// what it shares.
    ///
    /// The barometer and the pedometer go either way: neither is part of the
    /// question a pause asks, and the elevation filter is re-anchored on
    /// resume regardless. Only the location feed is kept, and only when
    /// something will read it — which is the whole of the energy argument for
    /// this feature. See ``RecordingLocationSource/startMovementWatch()``.
    ///
    /// The controller is asked here rather than handed its answer by the
    /// caller, because the caller's answer is by then as old as the journal
    /// write: a hiker refusing the notification prompt does it in exactly
    /// those seconds, and the refusal reaches
    /// ``MovementReminderController/isWatchingPausedRecording`` before it can
    /// reach this. A recorder with no controller keeps the behaviour a pause
    /// has always had — everything off.
    func parkLocationSensors() {
        hasParkedPausedSensors = true
        elevationSource?.stop()
        motionSource?.stop()
        guard movementReminders?.isWatchingPausedRecording == true else {
            source.stopRecordingUpdates()
            return
        }
        source.startMovementWatch()
    }

    /// This pause has stopped being watched — the hiker turned reminders
    /// off, or iOS said their reminders cannot be delivered at all.
    ///
    /// Called by ``MovementReminderController/reconcileWithPreferences()``
    /// for the switch and by
    /// ``MovementReminderController/reconcileWithAuthorization(prompting:)``
    /// for the refusal, because that is where each is *seen*; the recorder is
    /// where the feed they started can actually be stopped.
    ///
    /// Guarded twice, because the controller can see neither. On the phase: a
    /// switch flipped — or a permission prompt answered — during a running
    /// recording must not park its sensors. And on the parking having already
    /// happened, which is what makes this safe to reach before the pause's own
    /// journal write has landed.
    func stopWatchingPausedRecording() {
        guard phase == .paused, hasParkedPausedSensors else { return }
        parkLocationSensors()
    }

    /// Re-establishes — or clears — a pause's watch on a launch that found one
    /// in the journal.
    ///
    /// Both halves matter. A recording recovered into a pause is the very case
    /// this feature exists for: the hiker's phone died in their pocket at
    /// lunch and the walk carried on without it, so the anchor is worth having
    /// again. And a launch that decides *not* to watch has to say so out loud,
    /// because significant-change monitoring outlives the process that armed
    /// it — see ``RecordingLocationSource/stopMovementWatch()``.
    func rearmPausedMovementWatch(at coordinate: CLLocationCoordinate2D?) {
        let watches = movementReminders?.recordingDidPause(
            at: coordinate,
            on: clock()
        ) ?? false
        hasParkedPausedSensors = true
        if watches {
            source.startMovementWatch()
        } else {
            source.stopMovementWatch()
        }
    }
}
