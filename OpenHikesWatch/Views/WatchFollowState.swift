//
//  WatchFollowState.swift
//  OpenHikesWatch
//
//  Where the hiker is on the trail they are following, held apart from
//  everything that does not change per fix.
//
//  See ``WatchRecordingStats`` for the argument; this is the same one for the
//  other feed. What is here rather than there is everything a *trail* answers:
//  how far along, how far is left, whether the hiker is still on it.
//

import Foundation
import Observation
import OpenHikesShared

@MainActor
@Observable
final class WatchFollowState {
    /// The last match, or `nil` before the first fix has arrived — which is a
    /// state to say ("finding you") rather than a set of zeroes to draw.
    private(set) var position: WatchRouteTracker.Position?
    /// When the last fix landed, so a screen can say a reading is old rather
    /// than presenting a stale one as current.
    private(set) var updatedAt: Date?

    func update(_ position: WatchRouteTracker.Position, at date: Date = .now) {
        self.position = position
        updatedAt = date
    }

    func clear() {
        position = nil
        updatedAt = nil
    }
}
