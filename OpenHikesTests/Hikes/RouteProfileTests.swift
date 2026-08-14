//
//  RouteProfileTests.swift
//  OpenHikesTests
//
//  `RouteProfile` is the index behind three user-visible things: scrubbing
//  the elevation chart (distance → map coordinate), live auto-follow
//  (GPS fix → distance along the trail), and the widget progress
//  readout, which divides that distance by the hike's own length. If any of
//  those disagree the failure is silent — the graph marker simply sits
//  somewhere plausible but wrong.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Route profile")
struct RouteProfileTests {
    // MARK: Building the index

    @Test("cumulative distances ascend from zero")
    func distancesAscend() {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        #expect(profile.coordinates.count == Fixture.ridgeRoute.count)
        #expect(profile.distances.count == Fixture.ridgeRoute.count)
        #expect(profile.distances.first == 0)
        for (previous, next) in zip(profile.distances, profile.distances.dropFirst()) {
            #expect(next > previous)
        }
    }

    /// Keep the allocation-free route distance close to Core Location's
    /// geodesic result across an ordinary hiking route.
    @Test("the profile's total length stays close to Core Location")
    func totalMatchesPointToPoint() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        var expected = 0.0
        for (a, b) in zip(Fixture.ridgeRoute, Fixture.ridgeRoute.dropFirst()) {
            expected += CLLocation(latitude: b.latitude, longitude: b.longitude)
                .distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
        }
        let total = try #require(profile.distances.last)
        #expect(abs(total - expected) < expected * 0.005)
    }

    @Test("direct distance takes the short path across the antimeridian")
    func directDistanceHandlesAntimeridian() {
        let start = Fixture.antimeridianRoute[0]
        let end = Fixture.antimeridianRoute[1]
        let direct = RouteGeometry.distanceMeters(from: start, to: end)
        let coreLocation = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))

        #expect(direct > 5000)
        #expect(direct < 20_000)
        #expect(abs(direct - coreLocation) < coreLocation * 0.005)
    }

    @Test("stationary points keep cumulative distance finite")
    func stationaryPointsStayFinite() {
        let start = RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600)
        let route = [
            start,
            start,
            RouteCoordinate(latitude: 47.631, longitude: 12.86, elevation: 610),
        ]
        let profile = RouteProfile(route: route)

        #expect(profile.distances[0] == 0)
        #expect(profile.distances[1] == 0)
        #expect(profile.distances[2].isFinite)
        #expect(profile.distances[2] > 0)
    }

    /// Only points that carry elevation are plotted, but their x positions
    /// still have to be their real distance along the *whole* route — a
    /// sample's distance is not its index among the elevation-bearing points.
    @Test("elevation samples keep their true distance along the route")
    func samplesSkipPointsWithoutElevation() throws {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),                  // no elevation
            RouteCoordinate(latitude: 47.65, longitude: 12.86, elevation: 700),
        ]
        let profile = RouteProfile(route: route)
        #expect(profile.samples.count == 2)
        #expect(profile.distances.count == 3)
        let last = try #require(profile.samples.last)
        #expect(abs(last.distanceMeters - (profile.distances.last ?? 0)) < 0.001)
    }

    @Test("the elevation range spans the route's real low and high")
    func elevationRange() throws {
        let range = try #require(RouteProfile(route: Fixture.ridgeRoute).elevationRange)
        #expect(range.lowerBound == 100)
        #expect(range.upperBound == 260)
    }

    @Test("a route with no elevation data has no range to chart")
    func elevationRangeAbsent() {
        let flat = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),
        ]
        #expect(RouteProfile(route: flat).elevationRange == nil)
        #expect(RouteProfile(route: flat).samples.isEmpty)
    }

    @Test("an empty route indexes nothing rather than failing")
    func emptyRoute() {
        let profile = RouteProfile(route: [])
        #expect(profile.coordinates.isEmpty)
        #expect(profile.elevationRange == nil)
        #expect(profile.coordinate(atDistance: 0) == nil)
        #expect(profile.sample(atDistance: 0) == nil)
        #expect(profile.nearestPoint(to: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)) == nil)
    }

    // MARK: Scrubbing (distance → position)

    @Test("scrubbing resolves the nearest point, and clamps past both ends")
    func scrubLookup() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let total = try #require(profile.distances.last)

        let start = try #require(profile.coordinate(atDistance: 0))
        #expect(abs(start.latitude - Fixture.ridgeRoute[0].latitude) < 1e-9)

        let end = try #require(profile.coordinate(atDistance: total))
        #expect(abs(end.latitude - (Fixture.ridgeRoute.last?.latitude ?? 0)) < 1e-9)

        // A scrub can't leave the track, however far the finger travels.
        #expect(profile.coordinate(atDistance: -5000)?.latitude == start.latitude)
        #expect(profile.coordinate(atDistance: total * 10)?.latitude == end.latitude)
    }

    @Test("coordinate lookup interpolates within a route segment")
    func coordinateLookupInterpolates() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let midpointDistance = (profile.distances[1] + profile.distances[2]) / 2
        let midpoint = try #require(profile.coordinate(atDistance: midpointDistance))
        #expect(abs(midpoint.latitude - (profile.coordinates[1].latitude + profile.coordinates[2].latitude) / 2) < 1e-9)
        #expect(
            abs(midpoint.longitude - (profile.coordinates[1].longitude + profile.coordinates[2].longitude) / 2) < 1e-9
        )
    }

    @Test("elevation lookups only ever return charted samples")
    func sampleLookup() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let mid = try #require(profile.distances.last) / 2
        let sample = try #require(profile.sample(atDistance: mid))
        #expect(profile.samples.contains { $0.id == sample.id })
    }

}
