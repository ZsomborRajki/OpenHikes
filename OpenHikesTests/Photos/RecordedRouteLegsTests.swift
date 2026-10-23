//
//  RecordedRouteLegsTests.swift
//  OpenHikesTests
//
//  The shapes of route that a two-point fixture never reaches.
//
//  `LibraryPhotoMatchSparseLegTests` holds the rule to one leg at a time. A
//  real recording pauses in the middle, between two stretches that were
//  walked, and an imported file can carry a single point, the same point
//  twice, or points whose clocks run backwards. Each case is asked directly
//  of the legs here, so that a wrong answer names the leg that gave it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Recorded route legs")
struct RecordedRouteLegsTests {
    private static let latitude = 47.0
    private static let longitude = 12.0
    /// About 760 metres of longitude at this latitude: far enough apart that
    /// the middle of a leg is several times ``LibraryPhotoMatcher/maximumOffRouteMeters``
    /// from both of its ends.
    private static let longitudeStep = 0.01
    private static let metersPerDegreeLatitude = 111_320.0
    private static let toleranceMeters = 1.0
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    /// The point `step` legs east along the parallel the fixtures run on.
    private static func point(
        _ step: Int,
        timestamp: Date? = nil,
        provenance: RouteProvenance? = nil,
        boundary: RouteBoundary? = nil
    ) -> RouteCoordinate {
        RouteCoordinate(
            latitude: latitude,
            longitude: longitude + longitudeStep * Double(step),
            timestamp: timestamp,
            provenance: provenance,
            boundary: boundary
        )
    }

    /// `step` legs along the parallel, and `meters` north of it.
    private static func place(
        atStep step: Double,
        northByMeters meters: Double = 0
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: latitude + meters / metersPerDegreeLatitude,
            longitude: longitude + longitudeStep * step
        )
    }

    @Test("an empty route has no nearest point")
    func emptyRouteHasNoAnswer() {
        #expect(RecordedRouteLegs(route: []).nearestPoint(to: Self.place(atStep: 0)) == nil)
    }

    @Test("a route of one point is measured to that point")
    func singlePointIsAPoint() throws {
        let legs = RecordedRouteLegs(route: [Self.point(0)])

        let nearest = try #require(legs.nearestPoint(to: Self.place(atStep: 0, northByMeters: 30)))

        #expect(nearest.meters.isApproximatelyEqual(to: 30, absoluteTolerance: Self.toleranceMeters))
        let snappedOff = RouteGeometry.distanceMeters(from: nearest.coordinate, to: Self.place(atStep: 0))
        #expect(snappedOff.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
    }

    /// Two fixes at one place: a phone standing still, or a file that wrote a
    /// point twice. Its projection has no direction to run in.
    @Test("a leg of zero length is measured to its one place")
    func zeroLengthLegIsItsPlace() throws {
        let legs = RecordedRouteLegs(route: [Self.point(0), Self.point(0)])

        let nearest = try #require(legs.nearestPoint(to: Self.place(atStep: 0, northByMeters: 30)))

        #expect(nearest.meters.isApproximatelyEqual(to: 30, absoluteTolerance: Self.toleranceMeters))
        #expect(nearest.coordinate.latitude.isFinite)
        #expect(nearest.coordinate.longitude.isFinite)
    }

    /// A recording that stopped for the cable car between two walked
    /// stretches. Unlike the two-point fixture, both ends of the paused leg
    /// are also ends of legs that were walked.
    @Test("a pause between two walked legs is not projected onto, and both its ends still count")
    func pauseBetweenWalkedLegs() throws {
        let legs = RecordedRouteLegs(
            route: [Self.point(0), Self.point(1), Self.point(2, boundary: .paused), Self.point(3)]
        )

        let acrossThePause = try #require(legs.nearestPoint(to: Self.place(atStep: 1.5)))
        let toItsEnd = RouteGeometry.distanceMeters(from: Self.place(atStep: 1.5), to: Self.place(atStep: 1))
        #expect(acrossThePause.meters.isApproximatelyEqual(to: toItsEnd, absoluteTolerance: Self.toleranceMeters))
        #expect(acrossThePause.meters > LibraryPhotoMatcher.maximumOffRouteMeters)

        for step in [0.5, 1, 2, 2.5] {
            let walked = try #require(legs.nearestPoint(to: Self.place(atStep: step)))
            #expect(walked.meters.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
        }
    }

    /// A pause, then a bridge of two inferred legs, then a walked leg. The
    /// points between legs that are not walked have no walked leg to be an end
    /// of, so each must be tested on its own, and each still counts.
    @Test("points between legs that were not walked still count, each on its own")
    func pointsBetweenUnwalkedLegsStillCount() throws {
        let legs = RecordedRouteLegs(
            route: [
                Self.point(0),
                Self.point(1, boundary: .paused),
                Self.point(2, provenance: .inferred),
                Self.point(3, provenance: .inferred),
                Self.point(4),
            ]
        )

        for step in [0, 1, 2, 3, 3.5, 4] {
            let onTheRoute = try #require(legs.nearestPoint(to: Self.place(atStep: step)))
            #expect(onTheRoute.meters.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
        }
        let alongTheBridge = try #require(legs.nearestPoint(to: Self.place(atStep: 2.5)))
        let toItsEnd = RouteGeometry.distanceMeters(from: Self.place(atStep: 2.5), to: Self.place(atStep: 2))
        #expect(alongTheBridge.meters.isApproximatelyEqual(to: toItsEnd, absoluteTolerance: Self.toleranceMeters))
    }

    /// A boundary describes the leg arriving at its point, and the first point
    /// arrives from nowhere, so a pause written on it closes no leg.
    @Test("a pause on a route's first point leaves the leg after it walked")
    func pauseOnTheFirstPointIsIgnored() throws {
        let legs = RecordedRouteLegs(route: [Self.point(0, boundary: .paused), Self.point(1)])

        let nearest = try #require(legs.nearestPoint(to: Self.place(atStep: 0.5)))

        #expect(nearest.meters.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
    }

    /// A file whose clock runs backwards is still the line it draws. The legs
    /// join neighbours in route order, the way the map draws them, and never
    /// re-thread the points in time order across ground the line does not
    /// cover.
    @Test("legs join the route's neighbours, whatever their clocks say")
    func legsFollowRouteOrderNotTime() throws {
        let north = RouteCoordinate(
            latitude: Self.latitude + 1000 / Self.metersPerDegreeLatitude,
            longitude: Self.longitude + Self.longitudeStep,
            timestamp: Self.epoch.addingTimeInterval(600)
        )
        let legs = RecordedRouteLegs(
            route: [
                Self.point(0, timestamp: Self.epoch),
                Self.point(2, timestamp: Self.epoch.addingTimeInterval(1200)),
                north,
            ]
        )

        let onTheFirstLeg = try #require(legs.nearestPoint(to: Self.place(atStep: 1)))

        #expect(onTheFirstLeg.meters.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
    }
}
