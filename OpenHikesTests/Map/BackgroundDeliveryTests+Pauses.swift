//
//  BackgroundDeliveryTests+Pauses.swift
//  OpenHikesTests
//
//  The background live fix on a route a pause has split (#1350): the same
//  read ``WidgetFeedTests+Pauses.swift`` pins for the foreground, on the feed
//  that works with the phone in a pocket. That feed matches heading-first,
//  so it is asked both ways: cold, with nothing to go on, and with a course
//  and the distance the last fix matched at, which is the two-step search a
//  sparse feed makes.
//
//  Split from ``BackgroundDeliveryTests`` as an extension, because one test
//  type goes in a file and these share its relaunched tracker. The fixtures
//  are ``StationaryResume``'s.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

extension WidgetFeedSuites.BackgroundDeliveryTests {
    /// A few metres beside where the recording resumed, walking north along
    /// the piece, or with no course and no reference at all.
    @Test(
        "a background fix where a recording resumed without moving is drawn there",
        arguments: StationaryResume.allCases, [false, true]
    )
    func backgroundFixOnAStationaryPiece(piece: StationaryResume, carriesACourse: Bool) async throws {
        let hike = selectedHike(route: piece.route)
        let profile = RouteProfile(route: hike.route)
        let resumedAt = StationaryResume.resumedAt
        let beside = CLLocationCoordinate2D(latitude: resumedAt.latitude, longitude: resumedAt.longitude + 0.0001)
        if carriesACourse {
            // Where the recording resumed, on the distance axis.
            let resume = profile.distances[StationaryResume.beforeThePause.count - 1]
            defaults.set(resume, forKey: SettingsKey.lastMatchedDistance)
        }
        relaunchedTracker()

        await deliver(carriesACourse ? fix(at: beside, course: 0, speed: 1.2) : fix(at: beside))

        let drawn = try #require(SharedStore.load()?.liveFix).coordinate
        let drawnAt = CLLocationCoordinate2D(latitude: drawn.latitude, longitude: drawn.longitude)
        #expect(RouteGeometry.distanceMeters(from: drawnAt, to: resumedAt) < 1)
    }
}
