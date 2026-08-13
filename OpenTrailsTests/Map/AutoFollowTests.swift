//
//  AutoFollowTests.swift
//  OpenTrailsTests
//
//  Auto-follow decides, once per selected hike, *which part of the trail* a
//  walker is on — and on a trail that returns along its outbound leg, that is
//  a genuine choice between two positions that fit the same GPS fix equally
//  well. `RouteProfileTests` covers how a single fix is resolved. This covers
//  the state carried between fixes, which is what decides how long a wrong
//  answer lasts: an assumption that can be revised exactly once, versus one
//  that quietly holds for the rest of the walk.
//

import CoreLocation
import Foundation
@testable import OpenTrails
import Testing

@Suite("Auto-follow anchor")
struct FollowAnchorTests {
    private static let walkingBack: CLLocationDirection = 180

    /// The first fix of a hike has nothing to be continuous with, so the leg
    /// is worked out from the fix alone.
    @Test("the first fix has no anchor to continue from")
    func firstFixSeeds() {
        #expect(FollowAnchor.tieBreak(nil, course: nil) == nil)
        #expect(FollowAnchor.tieBreak(nil, course: Self.walkingBack) == nil)
    }

    /// The ordinary case: a match settled by a course anchors every fix after
    /// it, so GPS noise can't flip a walker between two legs of the trail.
    @Test("a confirmed anchor carries every later fix")
    func confirmedAnchorHolds() {
        let anchor = FollowAnchor.matched(at: 800, course: Self.walkingBack, from: nil)
        #expect(anchor.isCourseConfirmed)
        #expect(FollowAnchor.tieBreak(anchor, course: Self.walkingBack) == 800)
        #expect(FollowAnchor.tieBreak(anchor, course: nil) == 800, "a pause doesn't drop the anchor")
    }

    /// Opening the app while standing still — at the turn, at a viewpoint,
    /// anywhere a walker actually stops to look at their phone — leaves the
    /// match resting on the assumption that a hike starts at its start. On an
    /// out-and-back that assumption is wrong half the time, and continuity
    /// would then hold it wrong for the whole walk. So the first fix that
    /// carries a course is allowed to decide the leg again from scratch.
    @Test("an assumed anchor yields to the first real direction of travel")
    func unconfirmedAnchorIsReseeded() {
        let assumed = FollowAnchor.matched(at: 400, course: nil, from: nil)
        #expect(!assumed.isCourseConfirmed)

        // Still standing still: nothing better to go on, so keep the anchor
        // rather than re-deciding the leg on every poll.
        #expect(FollowAnchor.tieBreak(assumed, course: nil) == 400)

        // Walking again: work it out afresh, with the course this time.
        #expect(FollowAnchor.tieBreak(assumed, course: Self.walkingBack) == nil)
    }

    /// …and that re-seeding happens once, not once per stop. Confirmation is
    /// sticky, so a walker who settles onto the return leg and then stops for
    /// a photo doesn't have the leg re-decided when they set off again.
    @Test("confirmation survives a walker standing still")
    func confirmationIsSticky() {
        let confirmed = FollowAnchor.matched(at: 400, course: Self.walkingBack, from: nil)
        let paused = FollowAnchor.matched(at: 405, course: nil, from: confirmed)

        #expect(paused.isCourseConfirmed)
        #expect(FollowAnchor.tieBreak(paused, course: Self.walkingBack) == 405)
    }

    /// The whole sequence, on the trail that motivates it: a walker opens the
    /// app standing on the return leg of an out-and-back, then walks on.
    @Test("standing still on the return leg is corrected once walking resumes")
    func standingOnTheReturnLegIsCorrected() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = try #require(profile.distances.last)
        let standingOnTheWayBack = profile.coordinates[30]

        // Phone out, standing still: no course, so the start assumption wins
        // and places them on the outbound leg. This is the answer that used
        // to last the rest of the hike.
        let stationaryMatch = try #require(
            profile.nearestPoint(to: standingOnTheWayBack, near: FollowAnchor.tieBreak(nil, course: nil))
        )
        var anchor = FollowAnchor.matched(at: stationaryMatch.distanceAlongRoute, course: nil, from: nil)
        #expect(stationaryMatch.distanceAlongRoute < total / 2, "precondition: assumed onto the outbound leg")

        // They set off again, heading home.
        let walkingMatch = try #require(
            profile.nearestPoint(
                to: standingOnTheWayBack,
                near: FollowAnchor.tieBreak(anchor, course: Self.walkingBack),
                heading: Self.walkingBack
            )
        )
        anchor = FollowAnchor.matched(at: walkingMatch.distanceAlongRoute, course: Self.walkingBack, from: anchor)

        #expect(walkingMatch.distanceAlongRoute > total / 2, "corrected onto the return leg")
        #expect(abs(walkingMatch.distanceAlongRoute - profile.distances[30]) < 1)
        let progress = try #require(profile.fractionComplete(atDistance: walkingMatch.distanceAlongRoute))
        #expect(progress > 0.5, "and the percentage counts up rather than down")
        #expect(anchor.isCourseConfirmed, "so the correction can't be undone by the next pause")
    }
}

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
