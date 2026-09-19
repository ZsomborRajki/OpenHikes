//
//  WatchPhoneRecording.swift
//  OpenHikesShared
//
//  The phone's own recording, as the watch shows it, and the buttons that
//  drive it.
//
//  ## This is the direction that is safe
//
//  ``WatchRecordedWalk``'s header explains why a watch recording never streams
//  *to* the phone: two objects that can each be authoritative about "is a hike
//  being recorded?" is a synchronisation problem rather than a port. None of
//  that applies here, and it is worth being precise about why, because the two
//  look symmetrical and are not.
//
//  Going this way there is still exactly **one** authority: the phone's
//  `HikeRecorder`. The watch holds no recording state of its own for it,
//  reconciles nothing, and recovers nothing. It is a fourth *surface* on the
//  same recorder — beside the Live Activity, the Control Center toggle and the
//  Siri phrases, all of which already read and drive that one object — rather
//  than a fourth answer kept beside it.
//
//  That is also why the figures below are exactly `LiveRecordingReport`'s.
//  The phone already has one description of a live recording, the one it
//  speaks to Siri; the watch reads that rather than a second assembled for it,
//  so the two cannot come to disagree about what a hike in progress looks
//  like.
//
//  ## The clock is not sent
//
//  ``elapsedSeconds`` is the walk's clock *as of* ``updatedAt``, and the watch
//  runs it forward itself. A screen that received its stopwatch would need a
//  message a second for six hours; one that receives an anchor and ticks
//  locally needs a message only when a *figure* changes, which is what
//  ``updateFloorSeconds`` is sized for. The Live Activity makes the same move
//  for the same reason — a quiet walk costs no updates.
//

import Foundation

/// The phone's recording, as the watch draws it.
public struct WatchPhoneRecording: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    /// How long the phone waits between ordinary updates.
    ///
    /// The Live Activity's 20-second floor, and the same argument: the hiker's
    /// movement is what changes these figures, and nothing on a walk changes
    /// them faster than that in a way anybody reads. A state change — pausing,
    /// resuming, stopping — bypasses it, because that is the one thing a hiker
    /// has just pressed a button for and is waiting to see.
    public static let updateFloorSeconds: TimeInterval = 20

    /// What the phone's recorder is doing. A `String` raw value for the reason
    /// every other wire enum here has one: legible in a log, and stable if the
    /// cases are reordered.
    public enum State: String, Codable, Sendable {
        /// Nothing is being recorded on the phone. Distinct from *no phone*,
        /// which the watch knows from the link rather than from a payload.
        case idle = "idle"
        case paused = "paused"
        case recording = "recording"
    }

    public let schemaVersion: Int

    public var state: State
    /// `nil` while ``state`` is `idle`.
    public var sessionID: UUID?
    public var startedAt: Date?
    /// The walk's clock as of ``updatedAt``. See this file's header.
    public var elapsedSeconds: TimeInterval
    public var distanceMeters: Double
    /// The trail under the hiker, when the phone's live matcher has one.
    public var trailName: String?
    /// Whether ``trailName`` describes a match newer fixes have overtaken.
    ///
    /// Carried so the watch can hedge the way the phone's own screen does: a
    /// hiker who stepped off the path a minute ago must not be told flatly
    /// that they are still on it.
    public var isTrailNameStale: Bool
    public var updatedAt: Date

    public init(
        state: State,
        elapsedSeconds: TimeInterval = 0,
        distanceMeters: Double = 0,
        sessionID: UUID? = nil,
        startedAt: Date? = nil,
        trailName: String? = nil,
        isTrailNameStale: Bool = false,
        updatedAt: Date = .now
    ) {
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.trailName = trailName
        self.isTrailNameStale = isTrailNameStale
        self.updatedAt = updatedAt
        schemaVersion = Self.currentSchemaVersion
    }

    /// Nothing running on the phone.
    public static func idle(at date: Date = .now) -> Self {
        Self(state: .idle, updatedAt: date)
    }

    public var isActive: Bool {
        switch state {
        case .paused, .recording: true
        case .idle: false
        }
    }

    /// The instant the watch's own stopwatch should count from.
    ///
    /// `updatedAt` less the clock already run, so a screen can hand the system
    /// a date and let it tick — which is what makes a quiet walk free. `nil`
    /// while paused, because a paused walk's clock is not running and a
    /// ticking one would be a lie.
    public var clockAnchor: Date? {
        guard state == .recording else { return nil }
        return updatedAt.addingTimeInterval(-elapsedSeconds)
    }
}

/// A button on the watch, on its way to the phone's recorder.
public struct WatchRecordingCommand: SharedPayload, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    /// What was pressed.
    public enum Action: String, Codable, Sendable, CaseIterable {
        case pause = "pause"
        case resume = "resume"
        case start = "start"
        case stop = "stop"
    }

    public let schemaVersion: Int

    /// Distinguishes one press from another, so a reply can be matched to the
    /// command that earned it. A hiker who taps Pause twice must not have the
    /// first reply update a screen the second has already moved on from.
    public var id: UUID
    public var action: Action

    public init(action: Action, id: UUID = UUID()) {
        self.action = action
        self.id = id
        schemaVersion = Self.currentSchemaVersion
    }
}

/// What the phone did about a command.
///
/// Always carries the resulting state, refused or not, so the watch's screen
/// is corrected by every answer rather than only by the ones that worked. A
/// hiker who asked to start a hike while one was already running should see
/// the hike that *is* running, not an error beside a blank screen.
public struct WatchCommandOutcome: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    public var commandID: UUID
    /// `nil` when the command did what it said. Otherwise the phone's own
    /// sentence about why not — `HikeIntentFailure`'s, which is written to be
    /// read out loud and is therefore already short enough for a watch.
    public var refusal: String?
    public var recording: WatchPhoneRecording

    public init(
        commandID: UUID,
        recording: WatchPhoneRecording,
        refusal: String? = nil
    ) {
        self.commandID = commandID
        self.recording = recording
        self.refusal = refusal
        schemaVersion = Self.currentSchemaVersion
    }
}
