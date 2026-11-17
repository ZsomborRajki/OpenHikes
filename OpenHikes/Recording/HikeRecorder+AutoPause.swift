//
//  HikeRecorder+AutoPause.swift
//  OpenHikes
//
//  The recorder's half of Auto-Pause (#1470): what it does when
//  ``AutoPauseWatch`` says the hiker has stopped at a place, and when it says
//  they have walked on.
//
//  The rule is the watch's, in `OpenHikesShared`. What is here is the three
//  things only the recorder can do with its answers.
//
//  **A pause that began minutes ago.** A stop is decided five minutes into
//  it and counted from when it began. By then the stop's first minutes are in
//  the journal, on the map's trace and in the clock. The journal is cut back
//  to the fix the stop began at (``TrackJournal/pause(at:discardingPointsAfter:)``),
//  which leaves it as a pause by hand at that moment would have, and the live
//  figures are rebuilt from it, the way they are after the widget's fixes
//  are merged. So a replay after a crash and the preparation at Stop reach
//  the boundaries the hiker was shown, and the route a save writes carries
//  the same `RouteBoundary` a pause by hand leaves.
//
//  **A pause that keeps its feed.** A pause by hand parks the sensors, and
//  with Always access leaves significant location changes about 500 m apart.
//  That suits a reminder and cannot pick a walk up at the shop door. An
//  auto-pause is the app's guess, so it has to be cheap to undo: the feed
//  stays as a standing-still recording has it, and the fixes inside the stop
//  go to the watch and not to the track. That spends what an unpaused stop
//  spent before this existed; spending less on a long one needs a device
//  measurement first (*Energy policies in force* in AGENTS.md).
//
//  **A pause that is the app's.** Only a pause the app made ends by itself.
//  Resume during one resumes at once. Pause during one makes it the hiker's,
//  with a pause's parking and its reminder, and so does turning the switch
//  off, or a relaunch that finds the pause in the journal.
//

import CoreLocation
import Foundation
import OpenHikesShared

/// What the recorder keeps for Auto-Pause between fixes.
struct RecordingAutoPause {
    /// A fix delivered during an auto-pause, with the moment it arrived: the
    /// walk away is handed to the track afterwards, and a fix's age is judged
    /// against when it was delivered.
    struct HeldFix {
        let location: CLLocation
        let receivedAt: Date
    }

    /// More than a walk away is ever remembered by (the watch keeps sixteen),
    /// with room for the loose fixes between them.
    static let maximumHeldFixes = 64

    var watch: AutoPauseWatch
    /// Whether the pause in force is one the app made.
    var isPaused = false
    /// The newest fixes of the pause in force, oldest first.
    var heldFixes: [HeldFix] = []
    /// Rings at ``AutoPauseWatch/decisionDate``, so a stop no fix arrives
    /// during is still called.
    var timer: Task<Void, Never>?
    /// The rebuild of the live figures an auto-pause starts, held so that
    /// Stop can wait for it.
    var refresh: Task<Void, Never>?
}

extension AutoPauseWatch.Motion {
    init(_ state: RecordingMotionState) {
        switch state {
        case .nonPedestrian: self = .carried
        case .pedestrian: self = .onFoot
        case .stationary: self = .stationary
        case .unknown: self = .unknown
        }
    }
}

extension AutoPauseWatch.Fix {
    /// - Parameter elevation: a barometric height, or `nil` — see
    ///   ``RecordingElevationFilter/isBarometric``.
    init(_ location: CLLocation, elevation: Double?, motion: RecordingMotionState) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            elevation: elevation,
            speed: location.speed >= 0 ? location.speed : nil,
            motion: .init(motion)
        )
    }
}

extension HikeRecorder {
    /// The hiker's switch, read at every decision.
    var isAutoPauseEnabled: Bool {
        defaults.object(forKey: SettingsKey.autoPauseEnabled) as? Bool
            ?? SettingsDefault.autoPauseEnabled
    }

    /// Whether the recording is paused by the app, and will resume by itself.
    var isAutoPaused: Bool { phase == .paused && autoPause.isPaused }

    /// Shows the watch a fix delivered to a running recording, kept for the
    /// track or not.
    ///
    /// - Parameter elevation: the height the fix was given, when it was kept.
    /// - Returns: whether the fix made a stop of the place the hiker is at.
    ///   It is one of the stop's then, and joins no track.
    func observeForAutoPause(_ location: CLLocation, kept: Bool, elevation: Double?) -> Bool {
        let fix = AutoPauseWatch.Fix(
            location,
            elevation: elevationFilter.isBarometric ? elevation : nil,
            motion: latestMotionState
        )
        autoPauseEvidence?(.fix(fix, kept: kept))
        guard isAutoPauseEnabled else {
            autoPause.watch.reset()
            return false
        }
        guard case .stopped(let since) = autoPause.watch.observe(fix) else {
            scheduleAutoPauseCheck()
            return false
        }
        return beginAutoPause(since: since)
    }

    /// Asks the watch whether the hiker has stopped with no fix to say so.
    /// Called by the timer below, and at every change of motion.
    func checkAutoPause() {
        guard phase == .recording, isAutoPauseEnabled else { return }
        let motion = AutoPauseWatch.Motion(latestMotionState)
        if case .stopped(let since) = autoPause.watch.tick(at: clock(), motion: motion) {
            beginAutoPause(since: since)
        } else {
            scheduleAutoPauseCheck()
        }
    }

    /// The motion sensors' answer changed.
    func motionDidChange(to state: RecordingMotionState) {
        latestMotionState = state
        autoPauseEvidence?(.motion(.init(state), at: clock()))
        checkAutoPause()
    }

    /// Sets the one timer a stop is called by when no fix arrives during it.
    ///
    /// One at a time and never replaced: a hiker on the move names a new
    /// place to watch with every few fixes, and the timer set for the first
    /// of them asks about whichever is being watched when it rings, then
    /// sets the next. So a walk costs a wakeup every few minutes, beside the
    /// fixes that are already waking the app every few seconds. Once the
    /// moment has passed undecided, nothing is set: the next fix or change
    /// of motion asks again.
    private func scheduleAutoPauseCheck() {
        guard autoPause.timer == nil, phase == .recording,
              let date = autoPause.watch.decisionDate else { return }
        let delay = date.timeIntervalSince(clock())
        guard delay > 0 else { return }
        autoPause.timer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            autoPause.timer = nil
            checkAutoPause()
        }
    }

    /// Pauses the recording from `stoppedAt`, a moment already behind it.
    @discardableResult private func beginAutoPause(since stoppedAt: Date) -> Bool {
        guard phase == .recording, let journal, let sessionID else {
            autoPause.watch.reset()
            return false
        }
        autoPause.timer?.cancel()
        autoPause.timer = nil
        autoPause.isPaused = true
        autoPause.heldFixes = []
        phase = .paused
        cancelLiveMatching(clearWindow: false)
        journalFlushTask?.cancel()
        journalFlushTask = nil
        source.apply(resolvedEnergyProfile())
        enqueueJournalOperation { journal in
            try await journal.pause(at: stoppedAt, discardingPointsAfter: stoppedAt)
        }
        // The distance, the clock and the trace still hold the stop's first
        // minutes. Rebuilt from the journal once the cut above has landed,
        // and again if the walk away gets there first.
        autoPause.refresh = Task { [weak self] in
            await self?.refreshLiveStateAfterJournalMerge(expectedSessionID: sessionID, journal: journal)
        }
        publishSharedRecordingSnapshot(force: true)
        return true
    }

    /// A fix delivered while the app's own pause is in force.
    func observeWhileAutoPaused(_ location: CLLocation, receivedAt now: Date) {
        guard isAutoPauseEnabled else {
            takeOverAutoPause()
            return
        }
        guard LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.foregroundMaximumAge,
            now: now
        ) else { return }
        let fix = AutoPauseWatch.Fix(location, elevation: nil, motion: latestMotionState)
        autoPauseEvidence?(.fix(fix, kept: false))
        autoPause.heldFixes.append(RecordingAutoPause.HeldFix(location: location, receivedAt: now))
        autoPause.heldFixes.removeFirst(
            max(0, autoPause.heldFixes.count - RecordingAutoPause.maximumHeldFixes)
        )
        guard case .departed(let since) = autoPause.watch.observe(fix) else { return }
        endAutoPause(since: since)
    }

    /// Resumes the recording from `resumedAt`, the first fix of the walk
    /// away, and hands the track the fixes of that walk.
    ///
    /// Not ``resume()``: that one asks for precise location, reopens a
    /// journal a relaunch may have closed and restarts the sensors, and waits
    /// on each. None of it applies to a pause that kept its feed, and a wait
    /// here would let the next fix arrive ahead of the ones held. The resume
    /// goes on the journal's queue, where the points behind it follow in
    /// order.
    private func endAutoPause(since resumedAt: Date) {
        let walkedAway = autoPause.heldFixes.filter { $0.location.timestamp >= resumedAt }
        autoPause.isPaused = false
        autoPause.heldFixes = []
        enqueueJournalOperation { journal in
            try await journal.resume(at: resumedAt)
        }
        pendingResumeFlag = true
        lastAcceptedPoint = nil
        fixWindow?.reopen(at: resumedAt)
        phase = stats.pointCount == 0 ? .waitingForFix : .recording
        source.apply(resolvedEnergyProfile())
        for held in walkedAway {
            accept(held.location, receivedAt: held.receivedAt)
        }
        publishSharedRecordingSnapshot(force: true)
    }

    /// Makes the app's pause the hiker's: the sensors are parked and the
    /// resume reminder armed, as ``pause()`` does for a pause by hand. The
    /// journal already holds the pause.
    func takeOverAutoPause() {
        guard isAutoPaused else { return }
        resetAutoPause()
        hasParkedPausedSensors = false
        movementReminders?.recordingDidPause(
            at: lastAcceptedPoint?.coordinate,
            on: clock()
        )
        // The notice stops saying the recording resumes by itself.
        _ = resolvedEnergyProfile()
        // Behind whatever the journal is still writing of the pause.
        journalQueue.enqueue { [weak self] in
            await self?.parkLocationSensors()
        }
    }

    /// Forgets the watch and any pause of the app's: a pause or a resume by
    /// hand, and every way a recording ends.
    func resetAutoPause() {
        autoPause.timer?.cancel()
        autoPause.timer = nil
        autoPause.isPaused = false
        autoPause.heldFixes = []
        autoPause.watch.reset()
    }
}
