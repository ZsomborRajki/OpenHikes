//
//  WatchQueueHold.swift
//  OpenHikesShared
//
//  Which of the watch's queued walks its own recorder still holds back from
//  the phone.
//
//  ## A queued walk can still be the recorder's
//
//  Stop writes the walk to the queue before it lets the journal go, so a
//  process killed between the two leaves both, and the next launch asks the
//  queue whether the journal's walk already went — see
//  ``WatchRecordingRecovery``. A queued file that cannot be read just then
//  gets the answer a missing one does, and the walk is offered again, on
//  purpose. But the queued copy is still there, and can read again later.
//  A drain that sent it while the hiker was deciding, or after they chose
//  Continue, put the walk as it stood on the phone. The phone's import keeps
//  the first arrival of a session, so at Stop it dropped everything recorded
//  after Continue (#1572).
//
//  So a drain never sends the session the recorder holds: from the moment
//  its journal names it, through the hiker's answer and a recording carried
//  on, until the recorder's own walk of it is on the queue or thrown away.
//  Each answer reads the copy again, since it can be a batch of fixes ahead
//  of the journal — see ``WatchRecoveredRecording/tail(in:)``. Save keeps the
//  copy when it holds every fix the journal does, and writes the journal's
//  walk over it otherwise. Continue carries on from the copy's last fix when
//  it is ahead, and Stop's walk goes over it, because the queue keeps one
//  file a session. Discard lets the copy go, as the original Stop meant it
//  to.
//
//  ## Everything, until the journal is read
//
//  A launch drains as soon as the link is up, and until the journal has been
//  read nothing says which session it names. A walk sent then could still be
//  crossing when the check offers it, with its receipt yet to come. So every
//  walk waits for the check, which costs the journal's replay, and the drain
//  runs again when it answers.
//
//  ## Why it is here
//
//  *The watch app* in the repository instructions: there is no watch test
//  bundle. The recorder says which hold its phase means. What a hold keeps
//  back, and when a change of hold lets a walk go, is decided here.
//

import Foundation

/// The queued walks a drain must leave where they are, because the watch's
/// recorder may yet replace them.
public enum WatchQueueHold: Sendable, Equatable {
    /// Every walk, while the journal the last process left is being read.
    case everything
    /// None: every queued walk may go.
    case nothing
    /// The one session the recorder is recording or saving, or waiting on
    /// the hiker about.
    case session(UUID)

    /// Whether a drain must leave this walk on the queue unsent.
    public func holds(_ sessionID: UUID) -> Bool {
        switch self {
        case .everything: true
        case .nothing: false
        case .session(let held): held == sessionID
        }
    }

    /// Whether changing to `next` lets go of a walk this hold kept back.
    ///
    /// That is when a drain that skipped the walk has to run again. Nothing
    /// else may come to run one: a phone that stayed in range sends no
    /// reachability change.
    public func releases(into next: Self) -> Bool {
        switch self {
        case .everything: next != .everything
        case .nothing: false
        case .session(let held): !next.holds(held)
        }
    }
}
