//
//  TrailWidgetSnapshotPauseTests.swift
//  OpenHikesTests
//
//  The app's half of the trail widget's pauses (#1034): the snapshot it
//  writes names the paused legs of the hike it was built from, with both of
//  each one's ends kept through decimation. The decimation and the drawing
//  are `OpenHikesShared`'s, tested there under `swift test`
//  (`TrailWidgetPauseTests`); this holds the wiring from a stored route.
//

import CoreLocation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Trail widget snapshot pauses")
struct TrailWidgetSnapshotPauseTests {
    @Test("a paused hike's snapshot names its pause, between the two points the route joins")
    func snapshotNamesThePause() async throws {
        // Long enough to be decimated, with the pause where the stride would
        // drop one of its ends.
        let pause = 401
        let route = (0..<1000).map { index in
            RouteCoordinate(
                latitude: 47.63,
                longitude: 12.86 + Double(index) * 0.0001 + (index >= pause ? 0.05 : 0),
                boundary: index == pause ? .paused : nil
            )
        }
        let hike = Hike(title: "Drive between", distanceMeters: 1000, route: route)

        let snapshot = try #require(
            await BackgroundTrailTracker.buildSnapshotOffMain(from: HikeRouteInput(hike: hike), liveFix: nil)
        )

        #expect(snapshot.polyline.count <= 180)
        let position = try #require(snapshot.pauseIndices.first)
        #expect(snapshot.pauseIndices.count == 1)
        #expect(snapshot.polyline[position].longitude == route[pause].longitude)
        #expect(snapshot.polyline[position - 1].longitude == route[pause - 1].longitude)
        #expect(snapshot.runs.walkedRuns.count == 2)
    }

    @Test("an unpaused hike's snapshot names no pause")
    func unpausedSnapshotNamesNone() async throws {
        let hike = Hike(title: "Ridge", distanceMeters: 1000, route: Fixture.ridgeRoute)
        let snapshot = try #require(
            await BackgroundTrailTracker.buildSnapshotOffMain(from: HikeRouteInput(hike: hike), liveFix: nil)
        )
        #expect(snapshot.pauseIndices.isEmpty)
    }
}

// swiftlint:enable no_magic_numbers
