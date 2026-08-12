//
//  RouteProfileTests.swift
//  OpenTrailsTests
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
import OpenTrailsShared
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

        #expect(direct > 5_000)
        #expect(direct < 20_000)
        #expect(abs(direct - coreLocation) < coreLocation * 0.005)
    }

    @Test("stationary points keep cumulative distance finite")
    func stationaryPointsStayFinite() {
        let start = RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600)
        let route = [
            start,
            start,
            RouteCoordinate(latitude: 47.631, longitude: 12.86, elevation: 610)
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

        // Unanchored, the junction is ambiguous by construction — so it
        // resolves to the beginning of the loop rather than to whichever of
        // the two passes happens to be sampled nearer.
        let unanchored = try #require(profile.nearestPoint(to: junction))
        #expect(unanchored.offRouteMeters < 1)
        #expect(unanchored.distanceAlongRoute < total * 0.05)

        // Just set off: the match belongs at the beginning of the loop.
        let starting = try #require(profile.nearestPoint(to: junction, near: 0))
        #expect(starting.distanceAlongRoute < total * 0.05)

        // Nearly home: the same coordinate now belongs at the end of it.
        let finishing = try #require(profile.nearestPoint(to: junction, near: total))
        #expect(finishing.distanceAlongRoute > total * 0.95)
    }

    /// The first fix of a hike has no previous match to be continuous with,
    /// and on a trail that returns along its outbound leg every point has a
    /// twin that projects onto the route just as well. Left to the raw
    /// closest segment, which of the two won came down to which leg the GPX
    /// sampled a fraction of a metre nearer — so a walker who had just set
    /// off was placed at the finish about half the time, and the continuity
    /// reference then held them there for the rest of the hike.
    @Test("an unanchored fix at the trailhead starts the hike, not finishes it")
    func outAndBackStartsAtTheStart() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = try #require(profile.distances.last)
        // The return leg's own trailhead point: the closest segment to it is
        // the *last* one, by about three quarters of a metre.
        let trailhead = try #require(profile.coordinates.last)

        let match = try #require(profile.nearestPoint(to: trailhead))

        #expect(match.distanceAlongRoute < total * 0.05, "just set off — not nearly home")
        #expect(match.offRouteMeters < 2, "and the offset still describes the point returned")
    }

    /// The start bias only breaks ties, exactly as continuity only breaks
    /// ties: a fix genuinely up the trail belongs up the trail.
    @Test("preferring the start doesn't drag a match back to it")
    func startBiasOnlyBreaksTies() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let match = try #require(profile.nearestPoint(to: profile.coordinates[5]))

        #expect(abs(match.distanceAlongRoute - profile.distances[5]) < 1)
        #expect(match.offRouteMeters < 1)
    }

    /// Preferring the start is only an assumption, and it's the wrong one for
    /// a walker who opens the app already on the way back. Their course is
    /// the evidence that settles it: the outbound leg runs north here and the
    /// return leg runs south, so a walker heading south is on the return leg
    /// however well the outbound one also fits their position.
    @Test("a heading decides which leg of an out-and-back a fix is on")
    func headingPicksTheLeg() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = try #require(profile.distances.last)
        // A point on the way back, roughly a third of the way home.
        let onTheWayBack = profile.coordinates[30]
        let expected = profile.distances[30]

        let walkingBack = try #require(profile.nearestPoint(to: onTheWayBack, heading: 180))
        #expect(abs(walkingBack.distanceAlongRoute - expected) < 1)
        #expect(walkingBack.distanceAlongRoute > total / 2, "on the return leg, so past halfway")

        // The same coordinate walked the other way is the outbound leg's.
        let walkingOut = try #require(profile.nearestPoint(to: onTheWayBack, heading: 0))
        #expect(walkingOut.distanceAlongRoute < total / 2)

        // And with no course to go on it falls back to the start assumption.
        let standingStill = try #require(profile.nearestPoint(to: onTheWayBack))
        #expect(standingStill.distanceAlongRoute < total / 2)
    }

    /// The percentage the walker actually sees, end to end: the same fix that
    /// reads as a third of the way along the trail while walking out reads as
    /// two thirds while walking home.
    @Test("progress follows the leg the heading picked")
    func progressFollowsTheHeading() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let onTheWayBack = profile.coordinates[30]

        let out = try #require(profile.nearestPoint(to: onTheWayBack, heading: 0))
        let back = try #require(profile.nearestPoint(to: onTheWayBack, heading: 180))
        let outbound = try #require(profile.fractionComplete(atDistance: out.distanceAlongRoute))
        let returning = try #require(profile.fractionComplete(atDistance: back.distanceAlongRoute))

        #expect(abs((outbound + returning) - 1) < 0.02, "mirrored legs, so the two read as complements")
        #expect(returning > 0.5 && outbound < 0.5)
    }

    /// A course perpendicular to the trail — a walker crossing it, or a
    /// receiver reporting nonsense — matches neither leg. Rejecting every
    /// candidate would leave nothing to return, so the start assumption takes
    /// over rather than the match failing.
    @Test("a heading that agrees with no leg falls back to the start")
    func headingThatAgreesWithNothing() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = try #require(profile.distances.last)
        let onTheWayBack = profile.coordinates[30]

        let match = try #require(profile.nearestPoint(to: onTheWayBack, heading: 90))
        #expect(match.distanceAlongRoute < total / 2)
        #expect(match.offRouteMeters < 2)
    }

    /// Direction of travel seeds the match; it does not get to overrule an
    /// established one. A walker who stops at the turning point and steps a
    /// few metres back down the trail to look at something has not started
    /// the return leg, and their tracker shouldn't say they have.
    @Test("a heading doesn't overrule continuity once there's a match")
    func headingDoesNotOverruleContinuity() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = try #require(profile.distances.last)
        let outbound = profile.coordinates[15]

        // Facing back down the trail, but anchored to the outbound leg.
        let match = try #require(
            profile.nearestPoint(to: outbound, near: profile.distances[15], heading: 180)
        )
        #expect(abs(match.distanceAlongRoute - profile.distances[15]) < 1)
        #expect(match.distanceAlongRoute < total / 2, "still on the way out")
    }

    /// …and once a match exists, continuity carries it around the turning
    /// point onto the return leg, where progress counts up rather than back
    /// down the outbound one.
    @Test("continuity follows an out-and-back around its turn")
    func outAndBackFollowsTheReturnLeg() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = try #require(profile.distances.last)
        let onTheWayBack = profile.coordinates[25]

        let match = try #require(profile.nearestPoint(to: onTheWayBack, near: profile.distances[24]))

        #expect(abs(match.distanceAlongRoute - profile.distances[25]) < 1)
        #expect(match.distanceAlongRoute > total / 2, "past the turn, so on the return leg")
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

    // MARK: Progress (distance → fraction of the trail)

    @Test("progress runs from nothing at the start to all of it at the end")
    func progressSpansTheRoute() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let total = try #require(profile.distances.last)

        #expect(profile.totalDistanceMeters == total)
        #expect(profile.fractionComplete(atDistance: 0) == 0)
        #expect(profile.fractionComplete(atDistance: total) == 1)
        let half = try #require(profile.fractionComplete(atDistance: total / 2))
        #expect(abs(half - 0.5) < 1e-9)
        #expect(profile.remainingDistanceMeters(atDistance: 0) == total)
        #expect(profile.remainingDistanceMeters(atDistance: total) == 0)
    }

    /// The readout is fed by a live match, which can land a hair past the end
    /// of the route (or, projected onto the first segment, a hair before its
    /// start). Neither should ever print as 101% or −0%.
    @Test("progress clamps rather than overshooting the trail")
    func progressClamps() throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let total = try #require(profile.distances.last)

        #expect(profile.fractionComplete(atDistance: -50) == 0)
        #expect(profile.fractionComplete(atDistance: total * 2) == 1)
        #expect(profile.remainingDistanceMeters(atDistance: total * 2) == 0)
    }

    /// A GPX whose points are all in one place has no length to be a fraction
    /// of — the caller shows the trail without a percentage rather than
    /// dividing by zero.
    @Test("a zero-length route has no progress to report")
    func progressNeedsLength() {
        let stationary = RouteCoordinate(latitude: 47.63, longitude: 12.86, elevation: 600)
        let profile = RouteProfile(route: [stationary, stationary])

        #expect(profile.totalDistanceMeters == 0)
        #expect(profile.fractionComplete(atDistance: 0) == nil)
        #expect(RouteProfile(route: []).fractionComplete(atDistance: 0) == nil)
    }

    /// The app's progress row and the widget's "62% · 1.4 mi left" are two
    /// readouts of one position, derived on two sides of an App Group. They
    /// divide by the same total — `RouteProfile`'s and `Hike.distanceMeters`
    /// are the same haversine sum — so they must not be able to disagree.
    @Test("the app and the widget compute the same percentage")
    func progressMatchesTheWidget() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = profile.totalDistanceMeters
        let snapshot = SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Out and back",
            tintHex: "#FF0000",
            totalDistanceMeters: total,
            polyline: [],
            liveFix: .init(
                coordinate: .init(latitude: 47.63, longitude: 12.86),
                distanceAlongRouteMeters: total * 0.42,
                offRouteMeters: 3,
                timestamp: .now
            )
        )

        let app = try #require(profile.fractionComplete(atDistance: total * 0.42))
        let widget = try #require(snapshot.fractionComplete)
        #expect(abs(app - widget) < 1e-9)
        #expect(
            abs(profile.remainingDistanceMeters(atDistance: total * 0.42)
                - (snapshot.remainingDistanceMeters ?? 0)) < 1e-9
        )
    }

    // MARK: Degenerate routes

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
