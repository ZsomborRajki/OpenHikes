//
//  WidgetFeedTests+Pauses.swift
//  OpenHikesTests
//
//  The foreground live fix on a route a pause has split (#1350). A pause is
//  no distance (see ``RouteBoundary``), so a piece a recording resumed on and
//  never moved along has the very distance of the fix before the pause, and
//  a distance alone cannot tell the two apart. Read back through
//  ``RouteProfile/coordinate(atDistance:)``, a hiker standing where the
//  recording resumed was drawn on the widget a drive away, at the other end
//  of the pause or at the start of the next piece — the read #1334 found in
//  the photo picker.
//
//  Split from ``WidgetFeedTests`` as an extension, because one test type
//  goes in a file and these share its tracker. The fixtures are
//  ``StationaryResume``'s.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

extension WidgetFeedSuites.WidgetFeedTests {
    /// A few metres beside where the recording resumed, matched the way the
    /// hike's screen matches a fix, and published.
    @Test("a live fix where a recording resumed without moving is drawn there", arguments: StationaryResume.allCases)
    func liveFixOnAStationaryPiece(piece: StationaryResume) async throws {
        let hike = Fixture.hike(in: context, route: piece.route)
        let profile = RouteProfile(route: hike.route)
        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()
        let resumedAt = StationaryResume.resumedAt
        let beside = CLLocationCoordinate2D(latitude: resumedAt.latitude, longitude: resumedAt.longitude + 0.0001)
        var anchor: FollowAnchor?
        let fix = RouteFix(coordinate: beside, horizontalAccuracy: 5, course: nil, timestamp: .now)

        let match = try #require(FollowAnchor.advance(&anchor, on: profile, to: fix, scope: .wholeRoute))
        tracker.publishLiveFix(hike: hike, profile: profile, match: match)
        await tracker.waitForLiveFixPublish()

        let drawn = try #require(SharedStore.load()?.liveFix).coordinate
        let drawnAt = CLLocationCoordinate2D(latitude: drawn.latitude, longitude: drawn.longitude)
        #expect(RouteGeometry.distanceMeters(from: drawnAt, to: resumedAt) < 1)
    }
}
