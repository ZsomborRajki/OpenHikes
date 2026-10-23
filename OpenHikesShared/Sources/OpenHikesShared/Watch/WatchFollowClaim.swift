//
//  WatchFollowClaim.swift
//  OpenHikesShared
//
//  Whether a trail screen is asking for the watch's live position, and what
//  that asks of the one location receiver at each moment it could change.
//
//  ## Two owners, one receiver
//
//  The watch runs a single `CLLocationManager` for two jobs: a recording,
//  which owns it from Start to Stop, and a trail map, which wants it while the
//  map is on screen. Each owner's claim is its own. A recording outlives the
//  map it was started from, which is the point of it, but that does not make
//  the map's claim outlive the map: the screen claimed the feed, and the claim
//  goes with the screen.
//
//  Kept past it, it came back at Stop. A hiker who recorded along a trail,
//  went back to the list and pressed Stop on the Record tab had the receiver
//  started again for a map that was no longer there — `WatchRecorder.stop()`
//  takes the feed down and the model put it back for a claim nobody was
//  holding (issue #996). So leaving drops the claim whatever is recording, and
//  only the *receiver* is left to the recording.
//
//  ## Why it is here
//
//  *The watch app* in the repository instructions: there is no watch test
//  bundle. `WatchModel` keeps one of these, tells it each moment as it happens
//  and does to the receiver what it answers, so the whole decision runs on
//  the host.
//

import Foundation

/// A trail screen's claim on the location receiver.
public struct WatchFollowClaim: Equatable, Sendable {
    /// What to do with the receiver's following feed.
    public enum FeedChange: Equatable, Sendable {
        /// Start it for the screen that is asking.
        case start
        /// Stop it: nothing is asking any longer.
        case stop
        /// Leave it as it is, which under a recording means leaving it to the
        /// recording.
        case unchanged
    }

    /// Whether a trail screen is asking for live position right now.
    ///
    /// Remembered rather than answered on the spot, because the screen, the
    /// trail and the end of a recording arrive in any order: the *first*
    /// trail a watch is ever sent is asked for by a screen that opened with
    /// nothing to match against, and a recording that ends under an open map
    /// has taken the feed that map was drawing from.
    public private(set) var isClaimed: Bool

    public init() {
        isClaimed = false
    }

    /// A trail screen came on screen.
    ///
    /// - Parameters:
    ///   - holdingTrail: whether the watch has a trail to match fixes against.
    ///     Without one the claim waits for ``trailArrived(recording:)``.
    ///   - recording: whether a recording owns the receiver, in which case it
    ///     is already running and is the recording's to stop.
    public mutating func screenAppeared(holdingTrail: Bool, recording: Bool) -> FeedChange {
        isClaimed = true
        return holdingTrail && !recording ? .start : .unchanged
    }

    /// The trail screen left.
    ///
    /// The claim goes whatever is recording. Only the receiver is spared, and
    /// only while a recording owns it.
    public mutating func screenLeft(recording: Bool) -> FeedChange {
        isClaimed = false
        return recording ? .unchanged : .stop
    }

    /// A trail landed, which a screen that opened without one is waiting for.
    public func trailArrived(recording: Bool) -> FeedChange {
        isClaimed && !recording ? .start : .unchanged
    }

    /// A recording stopped and took the receiver down with it. Put back only
    /// for a screen still asking, or the dot on an open map freezes where the
    /// hiker pressed Stop.
    public func recordingStopped() -> FeedChange {
        isClaimed ? .start : .unchanged
    }
}
