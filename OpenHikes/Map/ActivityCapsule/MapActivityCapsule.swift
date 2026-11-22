//
//  MapActivityCapsule.swift
//  OpenHikes
//
//  The recording or the walk under way, on the map, wherever its own screen
//  is not the one in front: Stop or End, Pause or Resume, and what it is
//  doing, in one capsule.
//
//  The owner's decision (2026-11-20), after a hiker said the controls were
//  "too hidden in the details view": a mini player. On the activity's own
//  screen the sheet's bar holds them, at every detent — see ``RecordingView``
//  and ``HikeDetailView``'s toolbar. On every other screen this capsule does,
//  and a tap on its status goes back. The two are never on screen together.
//
//  Where it stands is the owner's too (2026-11-22): where the record button
//  stood while a recording was under way, at the foot of the map's leading
//  column, growing from there toward the middle of the map. Stop is the
//  first of it, so the red button a hiker's thumb knows is still the red
//  button there, and whichever pill shares the column — the maker's or the
//  camera's — stands on it. See `MapCoordinator+ActivityCapsule.swift`.
//
//  Stop is beside Pause here as on the bar: Stop asks first — see
//  ``RecordingStopQuestion`` — so a stray Stop costs less than a stray Pause.
//  The Live Activity has no Stop for a reason that does not carry over: a
//  stop that needs the app's question cannot be answered on the Lock Screen.
//
//  A recording outranks a walk, as on every surface (*The app* in
//  `AGENTS.md`), though a hiker never has both.
//

import Foundation
import Observation
import OpenHikesData

@MainActor
@Observable
final class MapActivityCapsule {
    /// What the capsule stands for.
    enum Activity: Equatable {
        case recording
        /// The walk along the hike with this id.
        case walk(hikeID: UUID)
    }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    let recorder: HikeRecorder
    let walk: TrailWalkSession
    let recordingStop: RecordingStopQuestion
    let walkEnd: WalkEndQuestion
    private let openRequests: HikeOpenRequests

    /// The sheet whose top screen says whether the activity's own screen is
    /// up — see ``follow(_:)``. Weak because the view that owns it outlives
    /// nothing here, and observed like any stored property, so the capsule
    /// is decided again once it is set.
    private weak var screens: SheetPresentation?

    init(
        recorder: HikeRecorder,
        walk: TrailWalkSession,
        recordingStop: RecordingStopQuestion,
        walkEnd: WalkEndQuestion,
        openRequests: HikeOpenRequests
    ) {
        self.recorder = recorder
        self.walk = walk
        self.recordingStop = recordingStop
        self.walkEnd = walkEnd
        self.openRequests = openRequests
    }

    /// Reads which screen is on top from `sheet`.
    func follow(_ sheet: SheetPresentation) {
        guard screens !== sheet else { return }
        screens = sheet
    }

    /// What the capsule stands for now, or `nil` when it stands down: nothing
    /// is under way, or the activity's own screen is the one in front.
    ///
    /// Read by the map's coordinator, which fades the capsule, and by the
    /// capsule's own view. It moves when an activity starts or ends and when
    /// a screen is pushed or popped, never per fix.
    var activity: Activity? {
        Self.activity(
            recordingLive: recorder.isActive,
            recordingOnTop: screens?.isRecordingPresented ?? false,
            walkedHikeID: walk.phase == nil ? nil : walk.walkedHikeID,
            hikeOnTop: screens?.presentedHikeID
        )
    }

    /// The rule, apart from the objects it reads, for the suite.
    nonisolated static func activity(
        recordingLive: Bool,
        recordingOnTop: Bool,
        walkedHikeID: UUID?,
        hikeOnTop: UUID?
    ) -> Activity? {
        if recordingLive {
            return recordingOnTop ? nil : .recording
        }
        guard let walkedHikeID, hikeOnTop != walkedHikeID else { return nil }
        return .walk(hikeID: walkedHikeID)
    }

    /// The status's tap: the activity's own screen, through the router the
    /// widget's taps go through.
    func openActivity() {
        switch activity {
        case .recording: openRequests.openRecording()
        case let .walk(hikeID): openRequests.open(hikeID: hikeID)
        case nil: break
        }
    }

    // MARK: The buttons

    /// Which of Pause and Resume the capsule offers.
    enum PauseControl: Equatable {
        case pause
        case resume
    }

    /// What the capsule's buttons are for, which moves only with a phase.
    struct Controls: Equatable {
        let activity: Activity
        /// Whether Stop, or End, is offered: not while a recording is being
        /// recovered or saved, or has failed.
        let offersStop: Bool
        /// Pause or Resume, or neither while there is nothing to pause.
        let pause: PauseControl?
    }

    /// What the capsule's buttons are for now, or `nil` when it stands down.
    /// Read by the map's coordinator, which shows and labels its buttons.
    var controls: Controls? {
        switch activity {
        case .recording:
            Controls(activity: .recording, offersStop: recorder.isStoppable, pause: Self.pause(for: recorder.phase))
        case let .walk(hikeID):
            Controls(
                activity: .walk(hikeID: hikeID),
                offersStop: walk.phase != nil,
                pause: walk.phase.map { $0 == .following ? .pause : .resume }
            )
        case nil:
            nil
        }
    }

    /// Pause while a recording takes fixes, Resume while it is paused.
    nonisolated static func pause(for phase: HikeRecorder.Phase) -> PauseControl? {
        switch phase {
        case .waitingForFix, .recording: .pause
        case .paused: .resume
        case .idle, .recovering, .saving, .failed: nil
        }
    }

    /// Stop or End: asks the question the activity's own bar asks.
    func stop() {
        switch activity {
        case .recording: Task { await recordingStop.ask() }
        case .walk: walkEnd.ask()
        case nil: break
        }
    }

    /// Pause or Resume.
    func togglePause() {
        switch activity {
        case .recording:
            if recorder.phase == .paused {
                Task { await recorder.resume() }
            } else {
                recorder.pause()
            }
        case .walk:
            walkEnd.togglePhase()
        case nil:
            break
        }
    }

    // MARK: What it says

    /// The phase, in the words the activity's screen uses.
    var statusTitle: String {
        switch activity {
        case .recording, nil:
            recorder.phase.accessibilityTitle
        case .walk:
            if walk.phase == .paused { String(localized: "Hike Paused") } else { String(localized: "Hike Active") }
        }
    }

    /// The clock and, for a recording, the distance, as they stand at the
    /// moment of asking — what VoiceOver reads out, which the status's own
    /// self-ticking text cannot hand to UIKit.
    var statusFigures: String {
        switch activity {
        case .recording, nil:
            let distance = Measurement(value: recorder.stats.distanceMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .wide, usage: .road))
            guard recorder.sessionStartedAt != nil else { return distance }
            return "\(HikeFormat.duration(recorder.elapsedSeconds())), \(distance)"
        case .walk:
            return HikeFormat.duration(walk.activeSeconds())
        }
    }
}
