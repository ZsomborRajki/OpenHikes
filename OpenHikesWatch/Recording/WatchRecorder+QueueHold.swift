//
//  WatchRecorder+QueueHold.swift
//  OpenHikesWatch
//
//  Which queued walks each of the recorder's phases keeps back from the
//  phone — see ``WatchQueueHold``. Apart from `WatchRecorder.swift` for that
//  file's length, as `WatchRecorder+AutoPause.swift` is.
//

import Foundation
import OpenHikesShared

extension WatchRecorder.Phase {
    /// Which queued walks a drain must leave unsent in this phase, because
    /// the recorder may yet replace one — see ``WatchQueueHold``.
    ///
    /// - Parameter sessionID: the recording's session, which each phase that
    ///   carries no walk of its own is about. A fresh recording's is on no
    ///   queue, so holding it keeps nothing back.
    func queueHold(recording sessionID: UUID) -> WatchQueueHold {
        switch self {
        // The session the journal names, which nothing knows yet: while it
        // is being read, and for as long as it cannot be (#1573). A walk
        // sent meanwhile could be the journal's, still crossing when a read
        // that works at last offers it (#1572). Discard lets the queue go.
        case .checkingJournal, .unreadableJournal: .everything
        case .interrupted(let recovered): .session(recovered.sessionID)
        case .unsaved(let walk): .session(walk.sessionID)
        case .preparing, .recording, .paused, .saving: .session(sessionID)
        case .idle, .saved, .failed: .nothing
        }
    }
}
