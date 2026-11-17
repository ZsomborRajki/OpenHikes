//
//  WatchRecorder+AutoPause.swift
//  OpenHikesWatch
//
//  Auto-Pause on the watch's own recordings (#1470): the recorder doing what
//  ``WatchAutoPause`` decides. Apart from `WatchRecorder.swift` for that
//  file's length, as the phone's `HikeRecorder+AutoPause.swift` is.
//

import CoreLocation
import Foundation
import HealthKit
import OpenHikesShared
import os

extension WatchRecorder {
    /// Follows the phone's Auto-Pause switch, as the library last said it.
    /// Turned off, a pause the app made becomes the hiker's, to resume by
    /// hand.
    func setAutoPauseEnabled(_ isEnabled: Bool) {
        guard autoPause.isEnabled != isEnabled else { return }
        autoPause.isEnabled = isEnabled
        guard !isEnabled else { return }
        autoPauseTimer?.cancel()
        autoPauseTimer = nil
        handOverAutoPause()
    }

    /// Pauses the recording from `stoppedAt`, a moment already behind it.
    ///
    /// The fixes kept since then were the stop's, so the accumulator takes
    /// them back and the journal says so in one line, which a recovery
    /// replays to the same boundary. The workout session pauses as it does
    /// for a pause by hand; the feed runs on, as it always does here.
    func beginAutoPause(since stoppedAt: Date) {
        autoPauseTimer?.cancel()
        autoPauseTimer = nil
        accumulator.pause(since: stoppedAt)
        journaling { try $0.record(.autoPaused(stoppedAt), at: .now) }
        workout.session?.pause()
        isAutoPaused = true
        phase = .paused
        stats.update(from: snapshot)
        publishGlance()
    }

    /// A fix delivered while Auto-Pause's own pause is in force: shown to
    /// the rule, and held for the track until the rule says whether it was
    /// the stop's or the walk away's.
    func receivedWhileAutoPaused(_ location: CLLocation) {
        guard let departure = autoPause.hold(AutoPauseWatch.Fix(location), as: location) else { return }
        if departure.beganBeforeThePause {
            // The stop was called on the clock, and the walk away arrived
            // after it: the cut took walking with it. Logged for a device
            // run to find — see ``WatchAutoPause``.
            Self.logger.notice("Auto-pause walk-away began before the pause was called")
        }
        workout.session?.resume()
        // From the first fix of the walk away, which the window would
        // otherwise refuse as taken before the resume.
        window.reopen(at: departure.since)
        journaling { try $0.record(.resumed(departure.since), at: .now) }
        isAutoPaused = false
        phase = .recording
        onAutoResume?()
        for walked in departure.walkedAway {
            received(walked)
        }
        publishGlance()
    }

    /// Sets the one timer a stop is called by when no fix arrives during it,
    /// as the phone's recorder does: never replaced, and asking about
    /// whichever place is being watched when it rings. Once that moment has
    /// passed undecided, the next fix asks instead.
    func scheduleAutoPauseCheck() {
        guard autoPauseTimer == nil, let date = autoPause.decisionDate else { return }
        let delay = date.timeIntervalSinceNow
        guard delay > 0 else { return }
        autoPauseTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            autoPauseTimer = nil
            guard phase == .recording else { return }
            if let stoppedAt = autoPause.tick(at: .now) {
                beginAutoPause(since: stoppedAt)
            } else {
                scheduleAutoPauseCheck()
            }
        }
    }

    /// Makes the app's pause the hiker's, to resume by hand, as the phone's
    /// recorder does when Pause is pressed during one.
    ///
    /// - Returns: whether there was a pause of the app's to take over.
    func takeOverAutoPause() -> Bool {
        guard isAutoPaused else { return false }
        handOverAutoPause()
        resetAutoPause()
        return true
    }

    /// Writes down that the pause in force, the app's until now, is the
    /// hiker's, so that a relaunch leaves it to them rather than taking it
    /// up again. The workout session already holds it, and the accumulator
    /// already stands paused.
    private func handOverAutoPause() {
        guard isAutoPaused else { return }
        isAutoPaused = false
        journaling { try $0.record(.paused(.now), at: .now) }
    }

    /// Forgets the place being watched and any pause the app made: a pause
    /// or a resume by hand, and every way a recording begins or ends.
    func resetAutoPause() {
        autoPauseTimer?.cancel()
        autoPauseTimer = nil
        autoPause.reset()
        if isAutoPaused { isAutoPaused = false }
    }
}

extension AutoPauseWatch.Fix {
    /// A watch fix as Auto-Pause reads it: no motion and no height, which
    /// the watch does not have to give it — see ``WatchAutoPause``.
    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed >= 0 ? location.speed : nil
        )
    }
}
