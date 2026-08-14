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

    /// Re-arms after every change, the same shape ``MapCoordinator`` uses:
    /// `withObservationTracking` fires once and then forgets, so an observer
    /// that does not re-register sees exactly one transition and then goes
    /// quiet for the rest of the hike.
    func observePowerState() {
        withObservationTracking {
            _ = powerMonitor.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateEnergyProfile()
                observePowerState()
            }
        }
    }
}
