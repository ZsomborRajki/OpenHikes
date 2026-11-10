//
//  PhotoTrailAnchorTests+Pauses.swift
//  OpenHikesTests
//
//  A photo, or a place, added from the map's pill while following a route a
//  pause has split (#1366). A pause is no distance (see ``RouteBoundary``),
//  so a piece a recording resumed on and never moved along has the very
//  distance of the fix before the pause, and a distance alone cannot tell the
//  two apart. Read back through ``RouteProfile/coordinate(atDistance:)``, the
//  live match of a hiker standing where the recording resumed pinned both a
//  drive away, at the other end of the pause or at the start of the next
//  piece — the read #1334 found in the photo picker and #1350 in the widget.
//
//  Beside it, what must go on holding: once the match is cleared, the graph's
//  persistent tracker is a distance again, and is read back as a scrub is.
//
//  Split from ``PhotoTrailAnchorTests`` as an extension, because one test
//  type goes in a file. The fixtures are ``StationaryResume``'s.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension PhotoTrailAnchorTests {
    /// About seven metres of longitude at the resume's latitude.
    private static let besideTheResume = 0.0001

    /// A few metres beside where the recording resumed, matched the way the
    /// hike's screen matches a fix, and left in a tracker the way it leaves
    /// one: the live match, and the persistent tracker moved onto it.
    private static func followedTracker(
        on profile: RouteProfile
    ) throws -> TrackerState {
        let resumedAt = StationaryResume.resumedAt
        let beside = CLLocationCoordinate2D(
            latitude: resumedAt.latitude,
            longitude: resumedAt.longitude + besideTheResume
        )
        var anchor: FollowAnchor?
        let fix = RouteFix(coordinate: beside, horizontalAccuracy: 5, course: nil, timestamp: .now)
        let match = try #require(FollowAnchor.advance(&anchor, on: profile, to: fix, scope: .wholeRoute))
        let tracker = TrackerState()
        tracker.showLiveMatch(at: match.distanceAlongRoute, on: match.coordinate)
        tracker.trackerDistance = match.distanceAlongRoute
        return tracker
    }

    @Test(
        "a live match where a recording resumed without moving pins a photo and a place there",
        arguments: StationaryResume.allCases
    )
    func liveMatchOnAStationaryPiece(piece: StationaryResume) throws {
        let profile = RouteProfile(route: piece.route)
        let tracker = try Self.followedTracker(on: profile)

        let live = tracker.liveMatch
        let scrubbed = tracker.trackerDistance

        let photo = try #require(PhotoTrailAnchor.coordinate(profile: profile, live: live, scrubbed: scrubbed))
        let place = try #require(PhotoTrailAnchor.placeCoordinate(profile: profile, live: live, scrubbed: scrubbed))

        #expect(RouteGeometry.distanceMeters(from: photo, to: StationaryResume.resumedAt) < 1)
        #expect(RouteGeometry.distanceMeters(from: place, to: StationaryResume.resumedAt) < 1)
    }

    /// Following switched off takes the live point away with the live
    /// distance. What the pill then pins to is the parked tracker, read back
    /// from its distance as a scrub's always was, and never the point the
    /// last match left behind.
    @Test("a cleared live match leaves the tracker its own point", arguments: StationaryResume.allCases)
    func clearedMatchLeavesTheTracker(piece: StationaryResume) throws {
        let profile = RouteProfile(route: piece.route)
        let tracker = try Self.followedTracker(on: profile)

        tracker.clearLiveMatch()

        #expect(tracker.liveMatch == nil)
        #expect(tracker.liveTrackerDistance == nil)
        let photo = try #require(
            PhotoTrailAnchor.coordinate(profile: profile, live: tracker.liveMatch, scrubbed: tracker.trackerDistance)
        )
        let readBack = try #require(profile.coordinate(atDistance: tracker.trackerDistance))
        #expect(photo.latitude == readBack.latitude)
        #expect(photo.longitude == readBack.longitude)
    }
}
