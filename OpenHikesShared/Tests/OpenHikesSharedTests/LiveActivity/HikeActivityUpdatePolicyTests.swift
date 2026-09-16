//
//  HikeActivityUpdatePolicyTests.swift
//  OpenHikesSharedTests
//
//  "Hike activity update policy", split out of HikeActivityTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Hike activity update policy")
struct HikeActivityUpdatePolicyTests {
    private static let base = HikeActivityAttributes.ContentState(
        distanceMeters: 1000,
        offRouteMeters: 5
    )

    /// ActivityKit throttles an app that updates too often, and a metre of
    /// drift is invisible at the width these numbers are drawn at.
    @Test("a distance change too small to see is not worth an update")
    func smallDistanceIsNotWorthAnUpdate() {
        var moved = Self.base
        moved.distanceMeters = 1010
        #expect(!moved.warrantsUpdate(comparedTo: Self.base))

        moved.distanceMeters = 1030
        #expect(moved.warrantsUpdate(comparedTo: Self.base))
    }

    /// The two changes that alter what the activity *says* rather than what it
    /// reads, and so must never be throttled away.
    @Test("pausing is always worth an update")
    func pausingIsAlwaysWorthAnUpdate() {
        var paused = Self.base
        paused.runState = .paused
        #expect(paused.warrantsUpdate(comparedTo: Self.base))
    }

    @Test("stepping off the trail is always worth an update")
    func leavingTheTrailIsAlwaysWorthAnUpdate() {
        var offRoute = Self.base
        offRoute.offRouteMeters = nil
        #expect(offRoute.warrantsUpdate(comparedTo: Self.base))
        #expect(Self.base.warrantsUpdate(comparedTo: offRoute))
    }

    /// The clock ticks by itself through `timerStart`, so spending an update
    /// on it would buy nothing at all.
    @Test("the elapsed clock alone is never worth an update")
    func elapsedAloneIsNeverWorthAnUpdate() {
        var later = Self.base
        later.elapsedSeconds += 600
        later.updatedAt = Self.base.updatedAt.addingTimeInterval(600)
        #expect(!later.warrantsUpdate(comparedTo: Self.base))
    }

    @Test("the same walk is recognised across a rename")
    func sameWalkIsRecognisedAcrossARename() {
        let hikeID = UUID()
        let original = HikeActivityAttributes(
            subject: .following(hikeID: hikeID),
            title: "Ridge",
            tintHex: "#FF0000",
            startedAt: .now
        )
        var renamed = original
        renamed.title = "Ridge Loop"
        renamed.tintHex = "#00FF00"
        #expect(original.describesSameWalk(as: renamed))

        var other = original
        other.subject = .following(hikeID: UUID())
        #expect(!original.describesSameWalk(as: other))
    }
}
