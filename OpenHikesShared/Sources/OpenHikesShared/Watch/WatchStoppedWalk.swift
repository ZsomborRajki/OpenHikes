//
//  WatchStoppedWalk.swift
//  OpenHikesShared
//
//  What becomes of a watch recording once Stop has been pressed, decided
//  without a disk or a watch.
//
//  ## Stop is not the end of the walk
//
//  Stop ends the workout session and the location feed, and neither can be
//  taken back. What it must not end is the walk: until the walk is on the
//  watch's disk queue it exists in the recorder's memory and nowhere else. A
//  write that fails there — a watch out of storage — used to leave the recorder
//  `.failed` with nothing but an OK button, and the next Start replaced the
//  fixes it was still holding. So a walk that could not be written stays
//  ``unsaved(_:)``, the same walk under the same session ID, until a retry
//  writes it or the hiker throws it away.
//
//  ## Why it is here
//
//  *The watch app* in the repository instructions: there is no watch test
//  bundle, so the decision is pushed down to where `swift test` reaches it, and
//  `WatchRecorder` keeps only the calls into Core Location and HealthKit. The
//  disk write is handed in, which is what lets a suite refuse the first one
//  and accept the second.
//

import Foundation

/// A recording after Stop.
public enum WatchStoppedWalk: Equatable, Sendable {
    /// On the disk queue, and so safe to offer to the phone.
    case saved(WatchRecordedWalk)
    /// Nothing worth keeping — see ``WatchRecordedWalk/isWorthKeeping``.
    case tooShort
    /// Stopped, and not on the disk queue. The only copy of the walk, held
    /// until ``retried(writing:)`` puts it there or the hiker discards it.
    case unsaved(WatchRecordedWalk)

    /// The first attempt to keep a walk, made the moment it stops.
    ///
    /// - Parameter write: puts a walk on the disk queue and says whether it
    ///   is there — `WatchStore.enqueue(_:)` on a watch.
    public static func settle(
        _ walk: WatchRecordedWalk?,
        writing write: (WatchRecordedWalk) -> Bool
    ) -> Self {
        guard let walk else { return .tooShort }
        return write(walk) ? .saved(walk) : .unsaved(walk)
    }

    /// Another attempt at an unsaved walk.
    ///
    /// Anything else is returned unchanged **without writing**: a walk that is
    /// already queued is queued once, however many times a retry is pressed.
    public func retried(writing write: (WatchRecordedWalk) -> Bool) -> Self {
        guard case .unsaved(let walk) = self else { return self }
        return Self.settle(walk, writing: write)
    }

    /// Whether this still holds the only copy of a walk, which is what must
    /// keep a new recording from starting over it.
    public var holdsUnsavedWalk: Bool {
        if case .unsaved = self { true } else { false }
    }
}
