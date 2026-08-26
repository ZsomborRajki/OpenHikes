//
//  HikePhotoTimelineTests.swift
//  OpenHikesTests
//
//  What a walk can and cannot say about where somebody was at a given second.
//
//  The interesting half of ``HikePhotoTimeline`` is the refusals. Placing a
//  photograph taken between two fixes is arithmetic; deciding that a
//  photograph taken twenty minutes after the walk finished, or in the middle
//  of a gap the receiver produced nothing across, has no place on the trail is
//  the part that keeps the feature honest — and the part that silently stops
//  working if a tolerance is widened without anyone noticing.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike photo timeline")
struct HikePhotoTimelineTests {
    private static let latitude: Double = 47.6300
    private static let longitude: Double = 12.8600
    /// ~111 m per step at this latitude, which is a minute of ordinary
    /// walking and makes a half-way interpolation easy to state.
    private static let latitudeStep = 0.001
    private static let stepSeconds: TimeInterval = 60
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)
    /// Half a metre, which is far below the accuracy of anything this app
    /// consumes and so is "the same point" for every purpose here.
    private static let toleranceMeters = 0.5

    /// A straight northward walk, one fix a minute.
    private static func route(steps: Int) -> [RouteCoordinate] {
        (0..<steps).map { index in
            RouteCoordinate(
                latitude: latitude + latitudeStep * Double(index),
                longitude: longitude,
                elevation: nil,
                timestamp: epoch.addingTimeInterval(stepSeconds * Double(index))
            )
        }
    }

    private static func date(atStep step: Double) -> Date {
        epoch.addingTimeInterval(stepSeconds * step)
    }

    private static func meters(
        from position: HikePhotoTimeline.Position,
        to coordinate: CLLocationCoordinate2D
    ) -> Double {
        RouteGeometry.distanceMeters(from: position.coordinate, to: coordinate)
    }

    @Test("a route with no timestamps has no timeline")
    func routeWithoutTimestampsHasNoTimeline() {
        let route = [
            RouteCoordinate(latitude: Self.latitude, longitude: Self.longitude),
            RouteCoordinate(
                latitude: Self.latitude + Self.latitudeStep,
                longitude: Self.longitude
            ),
        ]

        #expect(HikePhotoTimeline(route: route) == nil)
    }

    @Test("only the timestamped points of a route become fixes")
    func untimestampedPointsAreDropped() throws {
        var route = Self.route(steps: 4)
        route.insert(
            RouteCoordinate(latitude: Self.latitude, longitude: Self.longitude),
            at: 2
        )

        let timeline = try #require(HikePhotoTimeline(route: route))

        #expect(timeline.fixes.count == 4)
    }

    @Test("a photo taken on a fix is placed at that fix")
    func exactFixIsPlacedExactly() throws {
        let route = Self.route(steps: 5)
        let timeline = try #require(HikePhotoTimeline(route: route))

        let position = try #require(
            timeline.position(at: Self.date(atStep: 2))
        )

        #expect(position.secondsFromFix == 0)
        #expect(
            Self.meters(from: position, to: route[2].clCoordinate)
                < Self.toleranceMeters
        )
    }

    @Test("a photo taken between two fixes lands between them")
    func betweenFixesIsInterpolated() throws {
        let route = Self.route(steps: 5)
        let timeline = try #require(HikePhotoTimeline(route: route))

        let position = try #require(
            timeline.position(at: Self.date(atStep: 1.5))
        )

        let expected = CLLocationCoordinate2D(
            latitude: Self.latitude + Self.latitudeStep * 1.5,
            longitude: Self.longitude
        )
        #expect(Self.meters(from: position, to: expected) < Self.toleranceMeters)
        // Half a minute from either neighbour, and the nearer of the two is
        // what the review screen shows.
        #expect(position.secondsFromFix == Self.stepSeconds / 2)
    }

    @Test("a route point recorded out of order does not break the lookup")
    func unsortedRouteIsSortedFirst() throws {
        var route = Self.route(steps: 5)
        route.swapAt(1, 3)
        let timeline = try #require(HikePhotoTimeline(route: route))

        let position = try #require(
            timeline.position(at: Self.date(atStep: 3))
        )

        #expect(
            Self.meters(
                from: position,
                to: CLLocationCoordinate2D(
                    latitude: Self.latitude + Self.latitudeStep * 3,
                    longitude: Self.longitude
                )
            ) < Self.toleranceMeters
        )
    }

    /// A GPX writer that rounds to whole seconds produces these routinely, and
    /// two fixes sharing a timestamp would make the interpolation divide by
    /// zero.
    @Test("fixes sharing a second are collapsed to one")
    func duplicateTimestampsAreCollapsed() throws {
        var route = Self.route(steps: 3)
        route.append(
            RouteCoordinate(
                latitude: Self.latitude,
                longitude: Self.longitude,
                elevation: nil,
                timestamp: Self.date(atStep: 1)
            )
        )

        let timeline = try #require(HikePhotoTimeline(route: route))

        #expect(timeline.fixes.count == 3)
        let position = try #require(timeline.position(at: Self.date(atStep: 1.5)))
        #expect(position.secondsFromFix.isFinite)
    }

    @Test("a photo taken just before the walk is placed at the trailhead")
    func shortlyBeforeTheWalkIsPlacedAtTheStart() throws {
        let route = Self.route(steps: 5)
        let timeline = try #require(HikePhotoTimeline(route: route))
        let early = timeline.start.addingTimeInterval(
            -HikePhotoTimeline.graceInterval + 1
        )

        let position = try #require(timeline.position(at: early))

        #expect(
            Self.meters(from: position, to: route[0].clCoordinate)
                < Self.toleranceMeters
        )
    }

    @Test("a photo taken long before the walk is not placed at all")
    func longBeforeTheWalkIsRefused() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(steps: 5)))
        let early = timeline.start.addingTimeInterval(
            -HikePhotoTimeline.graceInterval - 1
        )

        #expect(timeline.position(at: early) == nil)
    }

    @Test("a photo taken long after the walk is not placed at all")
    func longAfterTheWalkIsRefused() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(steps: 5)))
        let late = timeline.end.addingTimeInterval(
            HikePhotoTimeline.graceInterval + 1
        )

        #expect(timeline.position(at: late) == nil)
    }

    /// The case that separates this from a naive lerp: the receiver produced
    /// nothing for an hour, so the straight line between the two fixes either
    /// side of the gap describes a route nobody walked.
    @Test("the middle of a long GPS gap is not placed")
    func middleOfAGapIsRefused() throws {
        let gap = HikePhotoTimeline.graceInterval * 8
        let route = [
            RouteCoordinate(
                latitude: Self.latitude,
                longitude: Self.longitude,
                elevation: nil,
                timestamp: Self.epoch
            ),
            RouteCoordinate(
                latitude: Self.latitude + Self.latitudeStep,
                longitude: Self.longitude,
                elevation: nil,
                timestamp: Self.epoch.addingTimeInterval(gap)
            ),
        ]
        let timeline = try #require(HikePhotoTimeline(route: route))

        #expect(timeline.position(at: Self.epoch.addingTimeInterval(gap / 2)) == nil)
    }

    @Test("the edges of a long GPS gap are still placed at their own fix")
    func edgesOfAGapAreStillPlaced() throws {
        let gap = HikePhotoTimeline.graceInterval * 8
        let route = [
            RouteCoordinate(
                latitude: Self.latitude,
                longitude: Self.longitude,
                elevation: nil,
                timestamp: Self.epoch
            ),
            RouteCoordinate(
                latitude: Self.latitude + Self.latitudeStep,
                longitude: Self.longitude,
                elevation: nil,
                timestamp: Self.epoch.addingTimeInterval(gap)
            ),
        ]
        let timeline = try #require(HikePhotoTimeline(route: route))
        let justInside = Self.epoch.addingTimeInterval(
            HikePhotoTimeline.graceInterval - 1
        )

        let position = try #require(timeline.position(at: justInside))

        #expect(position.secondsFromFix == HikePhotoTimeline.graceInterval - 1)
    }

    @Test("the search window is the walk plus the grace at both ends")
    func searchWindowCoversTheGrace() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(steps: 5)))

        let window = timeline.searchWindow

        #expect(
            window.lowerBound == timeline.start
                .addingTimeInterval(-HikePhotoTimeline.graceInterval)
        )
        #expect(
            window.upperBound == timeline.end
                .addingTimeInterval(HikePhotoTimeline.graceInterval)
        )
    }

    @Test("a walk of a single timestamped fix still has a timeline")
    func singleFixIsATimeline() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route(steps: 1)))

        let position = try #require(timeline.position(at: Self.epoch))

        #expect(timeline.start == timeline.end)
        #expect(position.secondsFromFix == 0)
    }

    @Test("a hike offers the scan only when its route carries timestamps")
    func hikeAdvertisesMatchability() throws {
        let context = try Fixture.modelContext()
        let stamped = Fixture.hike(in: context, route: Self.route(steps: 3))
        let bare = Fixture.hike(
            in: context,
            title: "No clock",
            route: [
                RouteCoordinate(
                    latitude: Self.latitude,
                    longitude: Self.longitude
                ),
            ]
        )

        #expect(stamped.canMatchLibraryPhotos)
        #expect(!bare.canMatchLibraryPhotos)
        #expect(bare.photoTimeline == nil)
    }

    @Test("a hike reports the library assets it has already taken")
    func hikeReportsImportedAssets() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route(steps: 3))
        hike.addPhoto(HikePhoto(assetLocalIdentifier: "asset-1"))
        hike.addPhoto(HikePhoto())

        #expect(hike.importedPhotoAssetIdentifiers == ["asset-1"])
    }
}
