//
//  RouteProfileTests.swift
//  OpenTrailsTests
//
//  `RouteProfile` is the index behind three user-visible things: scrubbing
//  the elevation chart (distance → map coordinate), live auto-follow
//  (GPS fix → distance along the trail), and the widget/Watch progress
//  readout, which divides that distance by the hike's own length. If any of
//  those disagree the failure is silent — the graph marker simply sits
//  somewhere plausible but wrong.
//

import CoreLocation
import Foundation
import Testing
@testable import OpenTrails

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

    /// The profile's total and the length shown on the hike are computed by
    /// two different code paths (this one, and `GPXImport.Track`) over the
    /// same points. The widget divides one by the other to get "62% done",
    /// so they have to land on the same number.
    @Test("the profile's total length matches the same route measured point-to-point")
    func totalMatchesPointToPoint() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        var expected = 0.0
        for (a, b) in zip(Fixture.ridgeRoute, Fixture.ridgeRoute.dropFirst()) {
            expected += CLLocation(latitude: b.latitude, longitude: b.longitude)
                .distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
        }
        let total = try #require(profile.distances.last)
        #expect(abs(total - expected) < 0.001)
    }

    /// Only points that carry elevation are plotted, but their x positions
    /// still have to be their real distance along the *whole* route — a
    /// sample's distance is not its index among the elevation-bearing points.
    @Test("elevation samples keep their true distance along the route")
    func samplesSkipPointsWithoutElevation() throws {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600),
            RouteCoordinate(latitude: 47.64, longitude: 12.86),                  // no elevation
            RouteCoordinate(latitude: 47.65, longitude: 12.86, elevation: 700)
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
            RouteCoordinate(latitude: 47.64, longitude: 12.86)
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
        #expect(profile.coordinate(atDistance: -5_000)?.latitude == start.latitude)
        #expect(profile.coordinate(atDistance: total * 10)?.latitude == end.latitude)
    }

    @Test("coordinate lookup interpolates within a route segment")
    func coordinateLookupInterpolates() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let midpointDistance = (profile.distances[1] + profile.distances[2]) / 2
        let midpoint = try #require(profile.coordinate(atDistance: midpointDistance))
        #expect(abs(midpoint.latitude - (profile.coordinates[1].latitude + profile.coordinates[2].latitude) / 2) < 1e-9)
        #expect(abs(midpoint.longitude - (profile.coordinates[1].longitude + profile.coordinates[2].longitude) / 2) < 1e-9)
    }

    @Test("elevation lookups only ever return charted samples")
    func sampleLookup() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let mid = try #require(profile.distances.last).halved
        let sample = try #require(profile.sample(atDistance: mid))
        #expect(profile.samples.contains { $0.id == sample.id })
    }

    // MARK: Auto-follow (position → distance)

    @Test("a fix on the trail matches at the right distance and reads as on-route")
    func matchOnTrail() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let target = profile.coordinates[3]
        let match = try #require(profile.nearestPoint(to: target))
        #expect(match.offRouteMeters < 1)
        #expect(match.offRouteMeters <= RouteProfile.followMatchThresholdMeters)
        #expect(abs(match.distanceAlongRoute - profile.distances[3]) < 0.001)
    }

    /// A fix that's near the trail but not on a vertex still has to match —
    /// this is the ordinary case while walking, and the reported offset is
    /// what auto-follow gates on.
    @Test("a fix beside the trail still matches, with an honest offset")
    func matchBesideTrail() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let vertex = profile.coordinates[2]
        // ~28 m east of the third vertex.
        let nearby = CLLocationCoordinate2D(latitude: vertex.latitude, longitude: vertex.longitude + 0.00032)
        let match = try #require(profile.nearestPoint(to: nearby))
        #expect(match.offRouteMeters > 10)
        #expect(match.offRouteMeters < RouteProfile.followMatchThresholdMeters)
    }

    @Test("the midpoint of a sparse segment matches the segment, not an endpoint")
    func sparseSegmentMidpoint() throws {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.63, longitude: 12.87)
        ]
        let profile = RouteProfile(route: route)
        let total = try #require(profile.distances.last)
        let match = try #require(
            profile.nearestPoint(to: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.865))
        )

        #expect(match.offRouteMeters < 1)
        #expect(abs(match.distanceAlongRoute - total / 2) < 1)
        #expect(match.offRouteMeters <= RouteProfile.followMatchThresholdMeters)
    }

    @Test("a fix beside the middle of a sparse segment reports its perpendicular offset")
    func sparseSegmentOffset() throws {
        let route = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.63, longitude: 12.87)
        ]
        let profile = RouteProfile(route: route)
        let fix = CLLocationCoordinate2D(
            latitude: 47.63 + 30 / 111_320,
            longitude: 12.865
        )
        let match = try #require(profile.nearestPoint(to: fix))

        #expect(match.offRouteMeters > 25)
        #expect(match.offRouteMeters < 35)
    }

    @Test("segment matching and interpolation take the short path across the antimeridian")
    func antimeridianSegment() throws {
        let route = Fixture.antimeridianRoute.map(RouteCoordinate.init)
        let profile = RouteProfile(route: route)
        let total = try #require(profile.distances.last)
        let match = try #require(
            profile.nearestPoint(to: CLLocationCoordinate2D(latitude: -17.705, longitude: 180))
        )
        let resolved = try #require(profile.coordinate(atDistance: match.distanceAlongRoute))

        #expect(match.offRouteMeters < 10)
        #expect(abs(match.distanceAlongRoute - total / 2) < 20)
        #expect(abs(abs(resolved.longitude) - 180) < 0.01)
    }

    /// Off the trail, the *caller* decides — the profile still returns its
    /// best match, but with an offset far past the threshold so auto-follow
    /// (and the widget feed) drop it.
    @Test("a fix far from the trail reports an offset past the follow threshold")
    func matchOffTrail() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let far = CLLocationCoordinate2D(latitude: 37.3350, longitude: -122.0200) // ~900 m east
        let match = try #require(profile.nearestPoint(to: far))
        #expect(match.offRouteMeters > RouteProfile.followMatchThresholdMeters)
    }

    /// The reason `nearestPoint` takes a reference distance at all: on a loop,
    /// the start and the finish are metres apart, so a fix near the junction
    /// is genuinely ambiguous. Without continuity, ordinary GPS jitter can
    /// throw the tracker a full lap; with it, the match stays where the
    /// walker actually is.
    @Test("continuity keeps a loop's start and finish from swapping places")
    func loopContinuity() throws {
        let profile = RouteProfile(route: Fixture.loopRoute)
        let total = try #require(profile.distances.last)
        let junction = profile.coordinates[0]

        let unanchored = try #require(profile.nearestPoint(to: junction))
        #expect(unanchored.offRouteMeters < 1)

        // Just set off: the match belongs at the beginning of the loop.
        let starting = try #require(profile.nearestPoint(to: junction, near: 0))
        #expect(starting.distanceAlongRoute < total * 0.05)

        // Nearly home: the same coordinate now belongs at the end of it.
        let finishing = try #require(profile.nearestPoint(to: junction, near: total))
        #expect(finishing.distanceAlongRoute > total * 0.95)
    }

    /// Continuity must not become stickiness: a reference from the far side
    /// of the loop can't drag a match that's genuinely elsewhere.
    @Test("continuity only breaks ties, it doesn't override the geometry")
    func continuityDoesNotOverrideDistance() throws {
        let profile = RouteProfile(route: Fixture.loopRoute)
        let total = try #require(profile.distances.last)
        let quarterIndex = profile.coordinates.count / 4
        let quarterPoint = profile.coordinates[quarterIndex]

        let match = try #require(profile.nearestPoint(to: quarterPoint, near: total))
        #expect(abs(match.distanceAlongRoute - profile.distances[quarterIndex]) < 1)
        #expect(match.offRouteMeters < 1)
    }

    /// The returned offset has to describe the point actually returned —
    /// callers gate "am I on the trail?" on it, so reporting the raw-closest
    /// vertex's offset alongside a tie-broken position would let a fix be
    /// accepted on the strength of a point that wasn't chosen.
    @Test("the reported offset belongs to the point that was returned")
    func offsetDescribesReturnedPoint() throws {
        let profile = RouteProfile(route: Fixture.loopRoute)
        let total = try #require(profile.distances.last)
        let fix = CLLocationCoordinate2D(
            latitude: profile.coordinates[0].latitude + 0.00005,
            longitude: profile.coordinates[0].longitude
        )
        let match = try #require(profile.nearestPoint(to: fix, near: total))
        let resolved = try #require(profile.coordinate(atDistance: match.distanceAlongRoute))
        let trueOffset = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
            .distance(from: CLLocation(latitude: resolved.latitude, longitude: resolved.longitude))
        #expect(abs(match.offRouteMeters - trueOffset) < 1)
    }

    /// A single-point "route" is degenerate but reachable (a GPX with one
    /// trackpoint); matching against it must answer rather than trap.
    @Test("a one-point route still answers")
    func singlePointRoute() throws {
        let profile = RouteProfile(route: [RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600)])
        let match = try #require(profile.nearestPoint(to: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)))
        #expect(match.distanceAlongRoute == 0)
        #expect(match.offRouteMeters < 1)
        #expect(profile.coordinate(atDistance: 999) != nil)
    }
}

private extension Double {
    var halved: Double { self / 2 }
}
