//
//  TrailWalkSession+Accepting.swift
//  OpenHikesTests
//
//  A matched fix on a trail whose offer the hiker has already accepted.
//
//  A match no longer starts a walk; it offers one, and the hiker's Start is
//  what begins it — see ``WalkOffer``. Most of the walk suites are about what
//  happens *after* that, and spelling the offer and the answer out before
//  every first fix would bury each of them under a question it is not asking.
//  This is the answer given in advance: wherever a match would have offered
//  a walk, the walk starts, and the match is then fed exactly as before.
//
//  Gated on ``TrailWalkSession/canStart(_:)`` — following on, no End still
//  standing, not a recording's draft — which is the same gate an offer is
//  made behind, so a suite asserting that one of those refuses a walk is
//  still asserting it. The offer itself is `TrailWalkSessionTests+Offers`' subject.
//

import Foundation
@testable import OpenHikes

extension TrailWalkSession {
    /// Starts a walk wherever this match would have offered one, then feeds
    /// the match. The abandonment check comes first, for the reason it does
    /// in ``recordForegroundMatch(hike:profile:distance:at:)``: a walk left
    /// unmatched for six hours is closed by this fix, and the fix is then a
    /// new walk's first.
    @discardableResult func acceptAndMatch(
        hike: Hike,
        profile: RouteProfile,
        distance: Double,
        at timestamp: Date? = nil
    ) -> Bool {
        endIfAbandoned()
        if canStart(hike) {
            start(hike: hike, routeLengthMeters: profile.totalDistanceMeters, at: timestamp)
        }
        return recordForegroundMatch(hike: hike, profile: profile, distance: distance, at: timestamp)
    }
}
