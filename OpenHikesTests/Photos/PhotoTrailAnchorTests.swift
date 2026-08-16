//
//  PhotoTrailAnchorTests.swift
//  OpenHikesTests
//
//  The one rule in this feature a view can't be trusted to get right: when a
//  photo gets a place on the trail, and when it deliberately doesn't.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Photo trail anchor")
struct PhotoTrailAnchorTests {
    private static let liveMatchMeters: Double = 120
    private static let scrubbedMeters: Double = 340

    @Test("an untouched tracker at the start is not a position")
    func placeholderZeroIsNotAnAnchor() {
        // `HikeDetailView` parks the tracker at 0 when the profile is built,
        // before anything has been matched or dragged. Pinning to that would
        // put every photo at the trailhead.
        #expect(PhotoTrailAnchor.distanceAlongRoute(live: nil, scrubbed: 0) == nil)
    }

    @Test("a live match at the trailhead is a position")
    func liveZeroIsAnAnchor() {
        // The other side of the same coin: someone photographing the sign at
        // the start of the walk is at 0 for real.
        #expect(PhotoTrailAnchor.distanceAlongRoute(live: 0, scrubbed: 0) == 0)
    }

    @Test("a scrub that has moved is a position")
    func movedScrubIsAnAnchor() {
        #expect(
            PhotoTrailAnchor.distanceAlongRoute(
                live: nil,
                scrubbed: Self.scrubbedMeters
            ) == Self.scrubbedMeters
        )
    }

    @Test("a live match outranks a scrub")
    func liveWinsOverScrub() {
        #expect(
            PhotoTrailAnchor.distanceAlongRoute(
                live: Self.liveMatchMeters,
                scrubbed: Self.scrubbedMeters
            ) == Self.liveMatchMeters
        )
    }

    @Test("a nonsense distance anchors nothing")
    func nonFiniteDistancesAreRefused() {
        #expect(PhotoTrailAnchor.distanceAlongRoute(live: .nan, scrubbed: 0) == nil)
        #expect(PhotoTrailAnchor.distanceAlongRoute(live: nil, scrubbed: .infinity) == nil)
        #expect(PhotoTrailAnchor.distanceAlongRoute(live: -1, scrubbed: 0) == nil)
    }

    @Test("no profile means no coordinate")
    func missingProfileYieldsNoCoordinate() {
        #expect(
            PhotoTrailAnchor.coordinate(
                profile: nil,
                live: Self.liveMatchMeters,
                scrubbed: 0
            ) == nil
        )
    }

    @Test("a route with no geometry yields no coordinate")
    func emptyRouteYieldsNoCoordinate() {
        let profile = RouteProfile(route: [])
        #expect(
            PhotoTrailAnchor.coordinate(
                profile: profile,
                live: 0,
                scrubbed: 0
            ) == nil
        )
    }

    @Test("a selected position resolves to a point on the route")
    func selectedPositionResolves() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let coordinate = try #require(
            PhotoTrailAnchor.coordinate(
                profile: profile,
                live: nil,
                scrubbed: Self.scrubbedMeters
            )
        )
        let expected = try #require(
            profile.coordinate(atDistance: Self.scrubbedMeters)
        )
        #expect(coordinate.latitude == expected.latitude)
        #expect(coordinate.longitude == expected.longitude)
    }

    @Test("a recording with no accepted fix has nowhere to pin")
    func recordingWithoutFixesHasNoAnchor() {
        #expect(PhotoTrailAnchor.recordingCoordinate(nil) == nil)
    }

    @Test("a recording pins to its last accepted fix")
    func recordingPinsToLastFix() throws {
        let last = try #require(Fixture.ridgeRoute.last)
        let coordinate = try #require(
            PhotoTrailAnchor.recordingCoordinate(
                RecordingPoint(
                    latitude: last.latitude,
                    longitude: last.longitude,
                    timestamp: .now,
                    horizontalAccuracy: 5
                )
            )
        )
        #expect(coordinate.latitude == last.latitude)
        #expect(coordinate.longitude == last.longitude)
    }

    @Test("an unusable recorded point is refused rather than pinned")
    func invalidRecordedPointIsRefused() {
        let broken = RecordingPoint(
            latitude: 91,
            longitude: 0,
            timestamp: .now,
            horizontalAccuracy: 5
        )
        #expect(PhotoTrailAnchor.recordingCoordinate(broken) == nil)
    }

    /// The regression the signature above exists to prevent. The draft `Hike`
    /// is inserted with `route: []` and only written when the recording stops,
    /// so a recording photo anchored from `currentHike.route` would never have
    /// been anchored at all — which is exactly what the first version did.
    @Test("a draft hike's route is empty while the walk is still going")
    func draftRouteIsEmptyDuringRecording() throws {
        let context = try Fixture.modelContext()
        let draft = Hike(
            title: "In progress",
            distanceMeters: 0,
            route: [],
            isRecording: true
        )
        context.insert(draft)

        #expect(draft.route.isEmpty)
    }
}
