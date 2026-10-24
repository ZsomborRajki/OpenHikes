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
//  ## Whose claim a leaving screen drops
//
//  Its own, and only while it still holds it. One map's leaving and the next
//  one's arrival are two SwiftUI callbacks whose order nothing promises, and a
//  claim that any leaving screen cleared would let a map on its way out take
//  the claim of the map that replaced it: the feed stopped under the new map,
//  or, under a recording, never put back for it at Stop. Each screen names
//  itself, and a screen that is no longer the claimant leaves nothing behind.
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

    /// The trail screen asking for live position right now, if any.
    ///
    /// Remembered rather than answered on the spot, because the screen, the
    /// trail and the end of a recording arrive in any order: the *first*
    /// trail a watch is ever sent is asked for by a screen that opened with
    /// nothing to match against, and a recording that ends under an open map
    /// has taken the feed that map was drawing from.
    public private(set) var claimant: UUID?

    /// Whether a trail screen is asking for live position right now.
    public var isClaimed: Bool { claimant != nil }

    public init() {
        claimant = nil
    }

    /// A trail screen came on screen. It holds the claim from now on, whoever
    /// held it before.
    ///
    /// - Parameters:
    ///   - screen: the screen, the same for its whole time on screen.
    ///   - holdingTrail: whether the watch has a trail to match fixes against.
    ///     Without one the claim waits for ``trailArrived(recording:)``.
    ///   - recording: whether a recording owns the receiver, in which case it
    ///     is already running and is the recording's to stop.
    public mutating func screenAppeared(_ screen: UUID, holdingTrail: Bool, recording: Bool) -> FeedChange {
        claimant = screen
        return holdingTrail && !recording ? .start : .unchanged
    }

    /// A trail screen left.
    ///
    /// Its claim goes whatever is recording. Only the receiver is spared, and
    /// only while a recording owns it. A screen another has taken the claim
    /// from leaves it, and the receiver, to that one.
    public mutating func screenLeft(_ screen: UUID, recording: Bool) -> FeedChange {
        guard claimant == screen else { return .unchanged }
        claimant = nil
        return recording ? .unchanged : .stop
    }

    /// A trail landed, which a screen that opened without one is waiting for.
    public func trailArrived(recording: Bool) -> FeedChange {
        isClaimed && !recording ? .start : .unchanged
    }

    /// A recording stopped and took the receiver down with it. Put back only
    /// for a screen still asking, or the dot on an open map freezes where the
    /// hiker pressed Stop — and only once there is a trail to match against,
    /// as ``screenAppeared(_:holdingTrail:recording:)`` would have it.
    public func recordingStopped(holdingTrail: Bool) -> FeedChange {
        isClaimed && holdingTrail ? .start : .unchanged
    }
}
