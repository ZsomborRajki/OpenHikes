//
//  WatchWorkoutOwnership.swift
//  OpenHikesShared
//
//  Which workout session, and which of its builders, the watch's recording
//  holds, and so which of HealthKit's callbacks speak for it.
//
//  ## A callback names its sender
//
//  `WatchRecorder` is the delegate of every session it starts, and HealthKit
//  calls it on its own queue, after the fact. A session ended at Stop can
//  still report a failure once the hiker has started the next walk, and a
//  builder discarded with it can still hand over a heart rate. Read as news
//  about whatever was recording, the first stopped the newer walk — a
//  workout that had failed nothing — and the second put the last walk's pulse
//  on the new one's screen (issue #1231). So each callback is weighed against
//  the session or builder it names, and only the ones this recording still
//  holds are heard.
//
//  ## A failure is asked twice
//
//  A failure stops the recording on a task, after the delegate has hopped to
//  the main actor, and between the two the hiker can press Stop and start
//  another walk. So the stop asks again when it runs, against what is held
//  then. Asked on the main actor in the same turn as the stop's own first
//  step, nothing can come between the answer and the walk it ends.
//
//  ## Why it is here
//
//  *The watch app* in the repository instructions: there is no watch test
//  bundle. The decision is made over the objects' identity alone, so the
//  watch hands in HealthKit's and the suite its own, and HealthKit stays out
//  of this package's library.
//

import Foundation

/// The workout session and live builder a recording holds, from the moment
/// it attaches them to the moment it ends them.
public struct WatchWorkoutOwnership<Session: AnyObject, Builder: AnyObject> {
    /// The session the recording holds, if any.
    public private(set) var session: Session?
    /// The session's builder, held and let go with it.
    public private(set) var builder: Builder?

    /// Holding nothing, as a recorder does before its first Start.
    public init() {
        session = nil
        builder = nil
    }

    /// Makes a session and its builder the recording's, whether it was just
    /// started or handed back by HealthKit after a crash. Whatever was held
    /// before speaks for nothing from here on.
    public mutating func attach(_ session: Session, builder: Builder) {
        self.session = session
        self.builder = builder
    }

    /// Lets the held pair go and hands it back to be ended. From here on
    /// neither speaks for any recording, however late it calls.
    public mutating func release() -> (session: Session, builder: Builder)? {
        defer {
            session = nil
            builder = nil
        }
        guard let session, let builder else { return nil }
        return (session, builder)
    }

    /// Whether a failure `failed` reported ends the recording.
    ///
    /// Only the held session's failure does, and only while a recording is
    /// running on it. Asked once when the failure arrives and again when the
    /// stop it schedules runs: in between, the hiker may have stopped that
    /// recording and started another, and the newer one has a session of its
    /// own.
    ///
    /// - Parameter isRecording: whether a recording is running or paused.
    public func failureEnds(_ failed: Session, isRecording: Bool) -> Bool {
        isRecording && session === failed
    }

    /// Whether figures a builder collected belong on the recording's screen:
    /// only the held builder's. One discarded with an earlier session would
    /// show that walk's reading on this one.
    public func admitsCollection(from collector: Builder) -> Bool {
        builder === collector
    }
}
