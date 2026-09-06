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
    /// Everything off *except* whatever can still notice the walker setting
    /// off again, for a recording that is paused.
    ///
    /// Called from the journal queue once the pause is durably written, so the
    /// walker cannot lose a pause boundary to a crash between the two — which
    /// is what this shares with ``stopLocationSensors()`` and the whole of
    /// what it shares.
    ///
    /// The barometer and the pedometer go either way: neither is part of the
    /// question a pause asks, and the elevation filter is re-anchored on
    /// resume regardless. Only the location feed is kept, and only when
    /// something will read it — which is the whole of the energy argument for
    /// this feature. See ``RecordingLocationSource/startMovementWatch()``.
    func parkLocationSensors(watchingForMovement: Bool) {
        elevationSource?.stop()
        motionSource?.stop()
        guard watchingForMovement else {
            source.stopRecordingUpdates()
            return
        }
        source.startMovementWatch()
    }

    /// The walker turned reminders off while this pause was being watched.
    ///
    /// Called by ``MovementReminderController/reconcileWithPreferences()``,
    /// which is where the switch is *seen*; the recorder is where the feed
    /// it started can actually be stopped. Guarded on the phase because the
    /// controller does not know one: a switch flipped during a running
    /// recording must not park its sensors.
    func stopWatchingPausedRecording() {
        guard phase == .paused else { return }
        parkLocationSensors(watchingForMovement: false)
    }

    /// Re-establishes — or clears — a pause's watch on a launch that found one
    /// in the journal.
    ///
    /// Both halves matter. A recording recovered into a pause is the very case
    /// this feature exists for: the walker's phone died in their pocket at
    /// lunch and the walk carried on without it, so the anchor is worth having
    /// again. And a launch that decides *not* to watch has to say so out loud,
    /// because significant-change monitoring outlives the process that armed
    /// it — see ``RecordingLocationSource/stopMovementWatch()``.
    func rearmPausedMovementWatch(at coordinate: CLLocationCoordinate2D?) {
        let watches = movementReminders?.recordingDidPause(
            at: coordinate,
            on: clock()
        ) ?? false
        if watches {
            source.startMovementWatch()
        } else {
            source.stopMovementWatch()
        }
    }
}
