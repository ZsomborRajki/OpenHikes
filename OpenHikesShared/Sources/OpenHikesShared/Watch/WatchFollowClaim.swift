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
//  ## Which trail it is asking for
//
//  A screen asks for its own trail, not for any. A map opened for one trail
//  while the watch still holds another draws a waiting view, and a feed
//  started for it would advance the held trail's tracker under a screen that
//  never shows it, at best accuracy, for as long as the phone stays away
//  (issue #1022). So the claim remembers the trail its screen named, and every
//  moment that could start the feed is told which trail the watch holds:
//  nothing starts until the two are the same.
//
//  ## Only while the app is on screen
//
//  Following without a recording has no workout session behind it, and is
//  meant to show a live position while the app is on screen and nothing
//  behind it (*The watch app* in the repository instructions). A map left in
//  the navigation stack when the app goes to the background gets no
//  `onDisappear`, and the receiver is configured to keep delivering in the
//  background for the recorder's sake, so the claim also hears the app leave
//  and come back. Leaving stops the feed and keeps the claim; coming back
//  starts it again for a map still asking whose trail is held.
//
//  "On screen" is the scene not being in the background. A lowered wrist with
//  Always On is `.inactive` and still draws the map, dimmed, so it keeps its
//  feed until watchOS returns to the clock and the scene reaches the
//  background.
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
        /// Stop it: nothing that can show it is asking any longer.
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

    /// The trail ``claimant`` asked for, which is the only one whose fixes it
    /// can show.
    public private(set) var claimedHikeID: UUID?

    /// Whether the app is on screen. A claim kept while it is not starts
    /// nothing until it is again.
    public private(set) var isAppOnScreen: Bool

    /// Whether a trail screen is asking for live position right now.
    public var isClaimed: Bool { claimant != nil }

    public init() {
        claimant = nil
        claimedHikeID = nil
        isAppOnScreen = true
    }

    /// A trail screen came on screen. It holds the claim from now on, whoever
    /// held it before.
    ///
    /// A feed already running for the screen it replaced is stopped when the
    /// trail it shows is not this screen's: the two screens' callbacks come
    /// in no promised order, and the one leaving may have started it.
    ///
    /// - Parameters:
    ///   - screen: the screen, the same for its whole time on screen.
    ///   - hikeID: the trail the screen shows.
    ///   - held: the trail the watch holds and can match fixes against, if
    ///     any. Until it is `hikeID`, the claim waits for
    ///     ``trailArrived(holding:recording:)``.
    ///   - recording: whether a recording owns the receiver, in which case it
    ///     is already running and is the recording's to stop.
    public mutating func screenAppeared(
        _ screen: UUID,
        asking hikeID: UUID,
        holding held: UUID?,
        recording: Bool
    ) -> FeedChange {
        claimant = screen
        claimedHikeID = hikeID
        guard !recording, isAppOnScreen else { return .unchanged }
        return held == hikeID ? .start : .stop
    }

    /// A trail screen left.
    ///
    /// Its claim goes whatever is recording. Only the receiver is spared, and
    /// only while a recording owns it. A screen another has taken the claim
    /// from leaves it, and the receiver, to that one.
    public mutating func screenLeft(_ screen: UUID, recording: Bool) -> FeedChange {
        guard claimant == screen else { return .unchanged }
        claimant = nil
        claimedHikeID = nil
        return recording ? .unchanged : .stop
    }

    /// The trail the watch holds changed, which a screen that opened without
    /// its own is waiting for. Starts the feed when the trail now held is the
    /// one the screen asked for, and stops it when it is not.
    public func trailArrived(holding held: UUID?, recording: Bool) -> FeedChange {
        guard isClaimed, !recording, isAppOnScreen else { return .unchanged }
        return held == claimedHikeID ? .start : .stop
    }

    /// A recording stopped and took the receiver down with it. Put back only
    /// for a screen still asking, or the dot on an open map freezes where the
    /// hiker pressed Stop — and only once the watch holds that screen's trail,
    /// and only while the app is on screen.
    public func recordingStopped(holding held: UUID?) -> FeedChange {
        isClaimed && isAppOnScreen && held == claimedHikeID ? .start : .unchanged
    }

    /// The app left the screen: the scene went to the background, with a map
    /// perhaps still pushed. The feed stops unless a recording owns it; the
    /// claim stays, for the map to have back when the app does.
    public mutating func appLeftScreen(recording: Bool) -> FeedChange {
        guard isAppOnScreen else { return .unchanged }
        isAppOnScreen = false
        return recording ? .unchanged : .stop
    }

    /// The app came back on screen. A map still asking gets its feed back,
    /// on the terms ``screenAppeared(_:asking:holding:recording:)`` would give
    /// it. Leaving stopped the feed, so there is nothing here to stop.
    public mutating func appReturned(holding held: UUID?, recording: Bool) -> FeedChange {
        guard !isAppOnScreen else { return .unchanged }
        isAppOnScreen = true
        return isClaimed && !recording && held == claimedHikeID ? .start : .unchanged
    }
}
