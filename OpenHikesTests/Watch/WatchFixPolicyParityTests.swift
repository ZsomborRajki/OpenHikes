//
//  WatchFixPolicyParityTests.swift
//  OpenHikesTests
//
//  Holds `WatchFixPolicy`'s thresholds to `RecordingFixPolicy`'s.
//
//  They are the same numbers because a hiker recording the same walk with a
//  watch and a phone should not end up with two tracks that disagree about
//  which fixes were real — one keeping a fix through the trees that the other
//  threw away. `WatchFixPolicy` restates them rather than importing them
//  because `RecordingFixPolicy` lives in this target and takes `CLLocation`s,
//  which the shared package deliberately cannot.
//
//  This is the gate that fails when one of them moves and the other does not.
//  It is deliberately *not* a claim that the two policies are the same policy:
//  the watch's has no speed gate and no course-change escape, because it takes
//  neither a speed nor a course. See `WatchFixPolicy`'s header for why those
//  two were left out rather than forgotten.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Watch fix policy parity")
struct WatchFixPolicyParityTests {
    @Test("the accuracy ceiling is one number in two files")
    func accuracyCeilingMatches() {
        #expect(
            WatchFixPolicy.maximumHorizontalAccuracy
                == RecordingFixPolicy.maximumHorizontalAccuracy
        )
    }

    @Test("the displacement floor is one number in two files")
    func displacementFloorMatches() {
        #expect(WatchFixPolicy.minimumDisplacement == RecordingFixPolicy.minimumDisplacement)
    }

    @Test("the heartbeat interval is one number in two files")
    func heartbeatMatches() {
        #expect(WatchFixPolicy.maximumInterval == RecordingFixPolicy.maximumInterval)
    }

    @Test("the follow threshold is one number in two files")
    func followThresholdMatches() {
        #expect(
            WatchRouteTracker.matchThresholdMeters
                == RouteProfile.followMatchThresholdMeters
        )
    }

    @Test("the matcher's tie-break constants are one pair in two files")
    func tieBreakConstantsMatch() {
        #expect(WatchRouteTracker.tieBreakToleranceMeters == RouteProfile.tieBreakToleranceMeters)
        #expect(WatchRouteTracker.courseAgreementDegrees == RouteProfile.courseAgreementDegrees)
        #expect(WatchRouteTracker.continuityWindowMeters == RouteProfile.continuitySearchRadiusMeters)
    }
}
