//
//  OffRouteSearchPolicyTests.swift
//  OpenHikesTests
//
//  "Off-route search policy", split out of AutoFollowTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// The latch that keeps live follow from rescanning the whole route on every
/// fix once the hiker has left it. A full scan is O(route), so on a long
/// trail an off-route hiker paid for one per fix — the one case where the
/// search can't short-circuit on a hit — to be told again that nothing is
/// near.
@Suite("Off-route search policy")
struct OffRouteSearchPolicyTests {
    /// The first fix has to be able to find the route from anywhere: there is
    /// no continuity window to search until something has matched.
    @Test("the first fix searches the whole route")
    func startsWide() {
        #expect(OffRouteSearchPolicy().scope == .wholeRoute)
    }

    @Test("a whole-route search that finds nothing narrows the next one")
    func emptyWholeRouteSearchNarrows() {
        var policy = OffRouteSearchPolicy()
        policy.record(matched: false, scope: .wholeRoute)
        #expect(policy.scope == .continuityWindow)
    }

    /// The re-arm. Without it, walking back onto a trail the window no longer
    /// covers — a there-and-back rejoined at the far end, say — would never be
    /// noticed, because the window is anchored to a match that never comes.
    @Test("the whole route is searched again after the re-arm interval")
    func rearmsAfterInterval() {
        var policy = OffRouteSearchPolicy()
        policy.record(matched: false, scope: .wholeRoute)

        for fix in 1..<OffRouteSearchPolicy.rearmIntervalFixes {
            policy.record(matched: false, scope: .continuityWindow)
            #expect(
                policy.scope == .continuityWindow,
                "fix \(fix) of \(OffRouteSearchPolicy.rearmIntervalFixes) should still be inside the window"
            )
        }

        policy.record(matched: false, scope: .continuityWindow)
        #expect(policy.scope == .wholeRoute)
    }

    /// A match means the hiker is on the route, where the window is both
    /// correct and cheap — and the next miss deserves a fresh full scan rather
    /// than inheriting a count from the last time they wandered off.
    @Test("a match returns the policy to its starting state")
    func matchResets() {
        var policy = OffRouteSearchPolicy()
        policy.record(matched: false, scope: .wholeRoute)
        for _ in 1..<OffRouteSearchPolicy.rearmIntervalFixes {
            policy.record(matched: false, scope: .continuityWindow)
        }

        policy.record(matched: true, scope: .continuityWindow)
        #expect(policy == OffRouteSearchPolicy())
        #expect(policy.scope == .wholeRoute)
    }
}
