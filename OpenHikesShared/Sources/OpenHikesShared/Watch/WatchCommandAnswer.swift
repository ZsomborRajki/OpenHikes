//
//  WatchCommandAnswer.swift
//  OpenHikesShared
//
//  What became of a button the watch pressed on the phone's recorder, and
//  which of those answers may change what the watch believes is recording.
//
//  ## Only the phone can say a recording stopped
//
//  A command ends one of two ways. The phone answers, with the state its
//  recorder is in afterwards (``WatchCommandOutcome``), or the watch never
//  hears back: the message could not be sent, `WCSession` gave up on it, or
//  the reply would not decode. Both end the wait, so both must reach the
//  model, and both carry a sentence for the hiker.
//
//  Only the first is evidence about the recorder. The watch used to answer
//  its own failures in the phone's shape, with an idle reading stamped *now*,
//  and that reading was newer than any the phone had sent, so it won: a
//  dropped Pause hid a hike still running on the phone, took the screen back
//  to the watch's own Start, and lifted the guard that keeps the watch from
//  starting a second recording of the same walk (issue #1123).
//
//  So a failure to get an answer is its own case and carries no reading. The
//  watch keeps the last one the phone sent. Losing the phone altogether is a
//  separate signal, reachability, which already clears that reading so a
//  screen never runs a stopwatch for a phone it cannot see.
//

import Foundation

/// The end of a command's wait: the phone's answer, or the watch's failure to
/// get one.
public enum WatchCommandAnswer: Equatable, Sendable {
    /// The phone performed the command, or refused it, and said what its
    /// recorder is doing now.
    case answered(WatchCommandOutcome)
    /// No answer came back. `reason` is the watch's own sentence for the
    /// hiker; nothing here describes the phone's recorder.
    case undelivered(commandID: UUID, reason: String)

    /// The command this answer ends.
    public var commandID: UUID {
        switch self {
        case .answered(let outcome): outcome.commandID
        case .undelivered(let commandID, _): commandID
        }
    }

    /// The sentence for the hiker, if the command did not do what it said.
    public var refusal: String? {
        switch self {
        case .answered(let outcome): outcome.refusal
        case .undelivered(_, let reason): reason
        }
    }

    /// The reading the watch should hold once this answer arrives over
    /// `current`.
    ///
    /// The phone's answer replaces what is held unless a newer push already
    /// overtook it. A failure to get one replaces nothing: see this file's
    /// header.
    public func reading(holding current: WatchPhoneRecording?) -> WatchPhoneRecording? {
        switch self {
        case .answered(let outcome): outcome.recording.reading(holding: current)
        case .undelivered: current
        }
    }
}

public extension WatchPhoneRecording {
    /// The reading the watch should hold once this one arrives over
    /// `current`: this one, unless it is older.
    ///
    /// A push and a command's reply can cross, and the newer one describes
    /// the state the phone is in now.
    func reading(holding current: WatchPhoneRecording?) -> WatchPhoneRecording? {
        if let current, updatedAt < current.updatedAt { return current }
        return self
    }
}
