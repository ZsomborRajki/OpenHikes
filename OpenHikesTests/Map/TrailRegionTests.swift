//
//  TrailRegionTests.swift
//  OpenHikesTests
//
//  The geometry the arming gate hands the system: the circle a trail sits
//  inside. On its own, without a tracker around it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Trail region")
struct TrailRegionTests {
    /// Metres between two coordinates, for asserting on a radius in the units
    /// the radius is in.
    private func distance(
        _ first: CLLocationCoordinate2D,
        _ second: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
    }

    @Test("a route with no points has no region")
    func emptyRouteHasNoRegion() {
        #expect(TrailRegion(route: []) == nil)
    }

    /// The circle has to cover the trail, or the gate would stand monitoring
    /// down with the hiker standing on it. Every point, plus the slack.
    @Test("the region covers every point of the route")
    func regionCoversTheRoute() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 37.3200, longitude: -122.0400),
            CLLocationCoordinate2D(latitude: 37.3500, longitude: -122.0200),
            CLLocationCoordinate2D(latitude: 37.3350, longitude: -122.0100),
        ]
        let region = try #require(TrailRegion(route: route))

        for point in route {
            #expect(distance(region.center, point) <= region.radiusMeters)
        }
    }

    /// The slack is what a hiker on the last stretch of the drive is inside,
    /// so it has to be real ground distance beyond the trail rather than a
    /// number the radius merely contains.
    @Test("the slack reaches beyond the far end of the route")
    func slackReachesBeyondTheRoute() throws {
        let end = CLLocationCoordinate2D(latitude: 37.3500, longitude: -122.0200)
        let route = [CLLocationCoordinate2D(latitude: 37.3200, longitude: -122.0400), end]
        let region = try #require(TrailRegion(route: route, slackMeters: 10_000))

        #expect(region.radiusMeters >= distance(region.center, end) + 9000)
    }

    /// A single-point route is a circle of just the slack, centred on it —
    /// the degenerate case the bounding box still answers.
    @Test("a one-point route is a circle of the slack")
    func onePointRouteIsTheSlack() throws {
        let point = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
        let region = try #require(TrailRegion(route: [point], slackMeters: 5000))

        #expect(region.radiusMeters.isApproximatelyEqual(to: 5000, absoluteTolerance: 1))
        #expect(distance(region.center, point) < 1)
    }

    /// The reason this is built on `TileBoundingBox` and not on min/max. A
    /// route either side of the antimeridian has an east edge numerically
    /// *west* of its west edge; averaging the two raw longitudes centres the
    /// circle on the far side of the planet, and every hiker on earth is then
    /// either always near the trail or never near it.
    @Test("a route across the antimeridian is centred on the route")
    func antimeridianRouteIsCentredOnTheRoute() throws {
        let route = [
            CLLocationCoordinate2D(latitude: -16.5, longitude: 179.9),
            CLLocationCoordinate2D(latitude: -16.5, longitude: -179.9),
        ]
        let region = try #require(TrailRegion(route: route, slackMeters: 1000))

        #expect(
            abs(region.longitude).isApproximatelyEqual(to: 180, absoluteTolerance: 0.05),
            "centred on the date line, not on Africa"
        )
        for point in route {
            #expect(distance(region.center, point) <= region.radiusMeters)
        }
    }

    /// A trail too big to fence gets no condition, and the caller reads that
    /// as *stay armed* — the same answer, and the same behaviour, as before
    /// the gate existed.
    @Test("a route larger than the maximum radius has no region")
    func oversizeRouteHasNoRegion() {
        let route = [
            CLLocationCoordinate2D(latitude: 36.0, longitude: -5.0),
            CLLocationCoordinate2D(latitude: 60.0, longitude: 25.0),
        ]

        #expect(TrailRegion(route: route) == nil)
    }

    /// The boundary the case above sits past, from the other side: a trail
    /// that fits still gets one.
    @Test("a day-hike-sized route is well within the maximum")
    func ordinaryRouteIsWithinTheMaximum() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402),
            CLLocationCoordinate2D(latitude: 47.5300, longitude: 19.0800),
        ]
        let region = try #require(TrailRegion(route: route))

        #expect(region.radiusMeters < TrailRegion.maximumRadiusMeters)
    }

    /// Longitude degrees are shortest at the poles, so a high-latitude box
    /// must not be measured as if it were at the equator — that would
    /// overstate the radius. Overstating is the safe direction, so this pins
    /// only that the scaling happens at all.
    @Test("a high-latitude route is narrower than the same span at the equator")
    func highLatitudeSpanIsScaled() throws {
        let span = 0.5
        let arctic = try #require(TrailRegion(
            route: [
                CLLocationCoordinate2D(latitude: 69.0, longitude: 0),
                CLLocationCoordinate2D(latitude: 69.0, longitude: span),
            ],
            slackMeters: 0
        ))
        let equator = try #require(TrailRegion(
            route: [
                CLLocationCoordinate2D(latitude: 0, longitude: 0),
                CLLocationCoordinate2D(latitude: 0, longitude: span),
            ],
            slackMeters: 0
        ))

        #expect(arctic.radiusMeters < equator.radiusMeters)
    }
}
