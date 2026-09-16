//
//  FollowInteractionTests.swift
//  OpenHikesTests
//
//  "Auto-follow interaction", split out of AutoFollowTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Auto-follow interaction")
struct FollowInteractionTests {
    @Test("toggling before the route profile is ready keeps the map highlight")
    func missingProfileDoesNotClearHighlight() {
        let update = FollowInteractionPolicy.highlightUpdate(
            autoFollowEnabled: false,
            isScrubbing: false,
            profile: nil,
            trackerDistance: 100
        )

        guard case .unchanged = update else {
            Issue.record("A missing profile should leave the highlight alone.")
            return
        }
    }

    @Test("scrubbing owns the persistent tracker during a live poll")
    func scrubbingOwnsTheTracker() {
        #expect(
            !FollowInteractionPolicy.appliesMatchToPersistentTracker(
                isScrubbing: true
            )
        )
        let update = FollowInteractionPolicy.highlightUpdate(
            autoFollowEnabled: true,
            isScrubbing: true,
            profile: RouteProfile(route: Fixture.ridgeRoute),
            trackerDistance: 100
        )
        guard case .unchanged = update else {
            Issue.record("Auto-follow should not move the pin under a scrub.")
            return
        }
    }

    @Test("turning auto-follow off restores the persistent tracker pin")
    func disablingRestoresTrackerPin() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let distance = try #require(profile.distances.last) / 2
        let update = FollowInteractionPolicy.highlightUpdate(
            autoFollowEnabled: false,
            isScrubbing: false,
            profile: profile,
            trackerDistance: distance
        )

        guard case .move(let coordinate) = update else {
            Issue.record("Expected the persistent tracker coordinate.")
            return
        }
        let expected = try #require(
            profile.coordinate(atDistance: distance)
        )
        #expect(abs(coordinate.latitude - expected.latitude) < 1e-9)
        #expect(abs(coordinate.longitude - expected.longitude) < 1e-9)
    }
}
