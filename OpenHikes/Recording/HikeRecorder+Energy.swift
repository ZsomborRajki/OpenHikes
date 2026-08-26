//
//  HikeRecorder+Energy.swift
//  OpenHikes
//
//  Where the recorder decides how hard to run the GPS.
//
//  ``RecordingEnergyPolicy`` says what the answer is; this file says when the
//  question gets asked. Three moments, and no timer:
//
//  * every accepted fix, because that is when ``RecordingDistanceAccumulator``
//    learns the walker has stopped or set off again, and it costs a struct
//    comparison against the profile already applied;
//  * a power-state change, because Low Power Mode and thermal pressure arrive
//    as notifications and can land during the half hour a walker spends at a
//    summit, when no fix is going to come along and prompt a re-evaluation;
//  * the start of a session, so a hike begun in Low Power Mode never spends a
//    single minute at full accuracy before noticing.
//
//  A timer was the obvious fourth and is deliberately absent: a recorder that
//  wakes up periodically to ask whether it should be using less energy is
//  itself a wakeup per period, for hours, to answer "no".
//

import Foundation
import Observation

extension HikeRecorder {
    /// What the GPS should be configured as, given everything currently known.
    func resolvedEnergyProfile() -> RecordingEnergyProfile {
        let power = powerMonitor.state
        let profile = RecordingEnergyPolicy.profile(
            for: RecordingEnergyPolicy.Conditions(
                isLowPowerModeEnabled: power.isLowPowerModeEnabled,
                thermalState: power.thermalState,
                // Only while fixes are actually being taken. A paused session
                // has a stale accumulator, and resuming from one should not
                // start out believing the walker is still standing where they
                // stopped an hour ago.
                isStationary: isCapturingFixes && accumulator.isStationary
            )
        )
        energyProfile = profile
        return profile
    }

    /// Re-evaluates and pushes the result at the location source. Cheap enough
    /// to call per fix: ``SystemRecordingLocationSource/apply(_:)`` compares
    /// against what it already applied and returns without touching
    /// CoreLocation when nothing moved, which is the overwhelming majority of
    /// calls.
    func updateEnergyProfile() {
        guard isCapturingFixes else { return }
        source.apply(resolvedEnergyProfile())
    }

    /// Re-evaluates the profile for the rest of the recorder's life, once per
    /// power-state change.
    ///
    /// An `Observations` sequence rather than the fire-once
    /// `withObservationTracking` + re-arm recursion this used to be — and that
    /// ``MapView/Coordinator`` still uses deliberately, because there the
    /// point is to stay synchronous and off SwiftUI's render path.
    ///
    /// Three things the loop gets that the recursion did not. The re-arm can't
    /// be forgotten: with `withObservationTracking`, an `onChange` that fails
    /// to re-register sees exactly one transition and then goes quiet for the
    /// rest of the hike, and nothing reports that it has. Cancellation is a
    /// real handle instead of a dropped closure. And the value has settled by
    /// the time it arrives — `onChange` fires *before* the write lands, which
    /// is why the old body had to hop through `Task { @MainActor in … }` to
    /// read anything true.
    ///
    /// `dropFirst()` because `Observations` opens by emitting the value it
    /// starts tracking, and this is a change subscription. Re-evaluating on
    /// arrival would be harmless — the session isn't capturing fixes yet at
    /// `init`, and ``updateEnergyProfile()`` returns early — but "only on a
    /// change" is what the rest of this file promises.
    func observePowerState() {
        powerStateObservation?.cancel()
        let monitor = powerMonitor
        powerStateObservation = Task { [weak self] in
            for await _ in Observations({ monitor.state }).dropFirst() {
                guard let self else { return }
                updateEnergyProfile()
            }
        }
    }
}

// MARK: - Field telemetry

extension HikeRecorder {
    /// Opens the MetricKit span covering this recording.
    ///
    /// The span is the whole session — a pause is inside it deliberately,
    /// because a paused recording still holds the app alive in the background
    /// and that is exactly the cost the span exists to attribute. What it
    /// deliberately excludes is everything after the GPS stops: saving,
    /// reviewing a matched route, and a walker taking ten minutes to name
    /// their hike are not GPS duty, and charging them to the recording would
    /// make an attentive user look like an expensive one.
    func beginFieldRecordingSpan() {
        endFieldRecordingSpan()
        fieldRecordingSpan = FieldSignpost.begin(.recordingSession)
    }

    /// Idempotent, and called from every path a session can leave by —
    /// stopping, failing and resetting. A span left open is not merely
    /// untidy: MetricKit reports nothing at all for an interval it never sees
    /// closed, so a single missed call site turns the whole measurement into
    /// silence rather than into a wrong number.
    func endFieldRecordingSpan() {
        guard let span = fieldRecordingSpan else { return }
        fieldRecordingSpan = nil
        FieldSignpost.end(span)
    }
}
