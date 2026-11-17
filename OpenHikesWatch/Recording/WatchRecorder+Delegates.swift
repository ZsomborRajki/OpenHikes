//
//  WatchRecorder+Delegates.swift
//  OpenHikesWatch
//
//  What Core Location and HealthKit tell the recorder. Apart from
//  `WatchRecorder.swift` for that file's length.
//

import CoreLocation
import Foundation
import HealthKit
import OpenHikesShared
import os

/// `nonisolated` on the extension, which is the spelling the repository
/// instructions require under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated extension WatchRecorder: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations fixes: [CLLocation]) {
        // Sorted here rather than trusted: Core Location batches, and a batch
        // out of order meets the accumulator's `interval > 0` guard and loses
        // the older fix silently.
        let sorted = fixes.sorted { $0.timestamp < $1.timestamp }
        onMainActor { [weak self] in
            guard let self else { return }
            for location in sorted {
                if phase == .recording {
                    received(location)
                } else if phase == .paused, autoPause.isPaused {
                    receivedWhileAutoPaused(location)
                } else {
                    receivedWhileIdle(location)
                }
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        onMainActor { [weak self] in self?.authorizationSettled(as: status) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Logged and not surfaced. Core Location reports a transient
        // `kCLErrorLocationUnknown` under trees and in gullies, on a walk
        // where it will resolve itself, and a banner for each one would be a
        // banner most of the way up a mountain.
        Self.logger.debug("Location failed: \(error.localizedDescription, privacy: .public)")
    }
}

nonisolated extension WatchRecorder: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // Read rather than obeyed. The hiker's buttons are the authority on
        // whether a recording is running — the same rule the app's recorder
        // keeps — and this is the system telling us what it did with the
        // session we asked for.
        Self.logger.debug("Workout session moved to state \(toState.rawValue, privacy: .public)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Self.logger.error("Workout session failed: \(error.localizedDescription, privacy: .public)")
        onMainActor { [weak self] in
            // Only the session this recording holds: one ended at an earlier
            // Stop can report its failure after the next walk has started,
            // and has no say over it (#1231).
            guard let self, workout.failureEnds(workoutSession, isRecording: phase.isActive) else { return }
            // The session is what keeps this app running, so losing it is not
            // a detail — but the walk so far is on the accumulator and stop()
            // will keep it. Stopping is therefore better than carrying on
            // into a suspension nobody would be told about. The walk reaches
            // the phone through ``onWalkQueued``, and the model hears through
            // ``onRecordingEnded`` that the receiver is down, as for a Stop.
            Task { await self.stop(afterFailureOf: workoutSession) }
        }
    }
}

nonisolated extension WatchRecorder: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Nothing here reads workout events. The walk's own pauses are the
        // accumulator's, and its distance is measured from the fixes rather
        // than from what HealthKit made of them.
    }

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        // Heart rate is all the data source collects, so it is all that
        // arrives here. A figure that reads another type has it collected
        // too — see ``WatchWorkoutCollection``.
        guard collectedTypes.contains(HKQuantityType(.heartRate)),
              let statistics = workoutBuilder.statistics(for: HKQuantityType(.heartRate))
        else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let beats = statistics.mostRecentQuantity()?.doubleValue(for: unit)
        // The sample's own time, so the screen can tell a reading from the
        // last one before the sensor stopped (#1024).
        let sampledAt = statistics.mostRecentQuantityDateInterval()?.end
        onMainActor { [weak self] in
            // Only the held builder's: one discarded at an earlier Stop would
            // put that walk's pulse on this one's screen.
            guard let self, workout.admitsCollection(from: workoutBuilder) else { return }
            stats.update(heartRateBPM: beats, sampledAt: sampledAt)
        }
    }
}
