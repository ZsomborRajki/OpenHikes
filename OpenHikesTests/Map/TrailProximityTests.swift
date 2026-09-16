//
//  TrailProximityTests.swift
//  OpenHikesTests
//
//  The geometry behind the arming decision, on its own: a box, a slack, and a
//  coordinate that is either inside or not. No tracker, no defaults, no
//  CoreLocation delivery — those are `BackgroundTrackingProximityTests`.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail proximity")
struct TrailProximityTests {
    /// Berchtesgaden-ish: a box about a kilometre across, far enough north
    /// that a degree of longitude is well under a degree of latitude, which is
    /// the case the padding has to scale for.
    private static let southWest = CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
    private static let northEast = CLLocationCoordinate2D(latitude: 47.6390, longitude: 12.8730)

    private func area(
        _ corners: [CLLocationCoordinate2D] = [southWest, northEast],
        hikeID: UUID = UUID()
    ) throws -> TrackedTrailArea {
        try #require(TrackedTrailArea(hikeID: hikeID, route: corners.map(RouteCoordinate.init)))
    }

    @Test("a point on the trail is near it")
    func onTheTrail() throws {
        let area = try area()
        #expect(TrailProximity.isNear(.init(latitude: 47.6340, longitude: 12.8650), of: area))
    }

    /// The reported case: a trail selected in one country, a phone in another.
    @Test("a point on the other side of the continent is not near it")
    func farAway() throws {
        let area = try area()
        // Munich, ~120 km away — well outside any slack this gate could
        // reasonably carry.
        #expect(!TrailProximity.isNear(.init(latitude: 48.1372, longitude: 11.5756), of: area))
    }

    /// The slack is what keeps the last stretch of the drive armed, so it has
    /// to be the thing being measured rather than the box.
    @Test("the slack decides the cases just outside the box")
    func slackBoundary() throws {
        let area = try area()
        // Due north of the box's north edge, by a little over half the slack.
        let north = CLLocationCoordinate2D(latitude: 47.6390 + 6000 / 111_320.0, longitude: 12.8650)

        #expect(TrailProximity.isNear(north, of: area), "inside the default slack")
        #expect(
            !TrailProximity.isNear(north, of: area, slackMeters: 1000),
            "and outside a slack narrower than the gap"
        )
    }

    /// Longitude degrees shrink toward the poles. Padding that ignored the
    /// latitude would reach about a third further east at this latitude than
    /// it does north, and the gate would quietly be a different size in
    /// Norway than in Spain.
    @Test("the east-west slack is scaled by latitude")
    func slackIsScaledByLatitude() throws {
        let area = try area()
        let metersPerDegreeLongitude = 111_320.0 * cos(47.634 * .pi / 180)
        let east = CLLocationCoordinate2D(
            latitude: 47.6340,
            longitude: 12.8730 + 9000 / metersPerDegreeLongitude
        )

        #expect(TrailProximity.isNear(east, of: area), "9 km east is inside a 10 km slack")
        #expect(
            !TrailProximity.isNear(
                .init(latitude: 47.6340, longitude: 12.8730 + 11_000 / metersPerDegreeLongitude),
                of: area
            ),
            "11 km east is not"
        )
    }

    /// A route stepping over the date line has a box whose west edge is east
    /// of its east edge. Taken as a plain interval that box spans the globe
    /// the long way round and every point on earth is "near" the trail — the
    /// failure ``TileBoundingBox`` exists to prevent, here in degrees rather
    /// than in tile columns.
    @Test("a trail across the antimeridian is near itself and nothing else")
    func antimeridian() throws {
        let area = try area(Fixture.antimeridianRoute)

        #expect(TrailProximity.isNear(.init(latitude: -17.705, longitude: 179.99), of: area))
        #expect(TrailProximity.isNear(.init(latitude: -17.705, longitude: -179.99), of: area))
        #expect(
            !TrailProximity.isNear(.init(latitude: -17.705, longitude: 0), of: area),
            "the meridian opposite is half a world away, not in the middle of the box"
        )
    }

    @Test("a route with no points has no area")
    func emptyRoute() {
        #expect(TrackedTrailArea(hikeID: UUID(), route: []) == nil)
    }

    /// It is stored in `UserDefaults` and read back by a later launch, so the
    /// round trip is part of the contract rather than an implementation
    /// detail.
    @Test("an area survives being encoded and decoded")
    func codableRoundTrip() throws {
        let original = try area()

        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(TrackedTrailArea.self, from: data)

        #expect(restored == original)
    }
}
