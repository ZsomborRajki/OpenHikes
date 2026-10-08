//
//  RouteGeometryLengthTests.swift
//  OpenHikesTests
//
//  The one length of a line.
//
//  An imported file's distance, a downloaded route's, a drawn leg's and a
//  review section's used to be summed by six private copies of the same loop,
//  and ``CommunityImport`` could only promise in a comment that its sum was
//  ``GPXImport``'s. Now both read ``RouteGeometry/lengthMeters(of:)``, and
//  what it adds up is pinned here.
//

import CoreLocation
import Foundation
@testable import OpenHikesData
import Testing

@Suite("Route length")
struct RouteGeometryLengthTests {
    private static let start = CLLocationCoordinate2D(latitude: 47.55, longitude: 12.92)
    private static let middle = CLLocationCoordinate2D(latitude: 47.56, longitude: 12.93)
    private static let end = CLLocationCoordinate2D(latitude: 47.56, longitude: 12.95)

    @Test("a line is as long as its legs, one after another")
    func sumsTheLegs() {
        let legs = RouteGeometry.distanceMeters(from: Self.start, to: Self.middle)
            + RouteGeometry.distanceMeters(from: Self.middle, to: Self.end)

        #expect(RouteGeometry.lengthMeters(of: [Self.start, Self.middle, Self.end]) == legs)
    }

    @Test("a point and nothing at all have no length")
    func needsTwoPoints() {
        #expect(RouteGeometry.lengthMeters(of: []) == 0)
        #expect(RouteGeometry.lengthMeters(of: [Self.start]) == 0)
        #expect([RouteCoordinate]().lengthMeters == 0)
    }

    /// The stored route's spelling is the same sum, and a pause does not
    /// shorten it: the line still runs from where the hiker stopped to where
    /// they started again.
    @Test("a stored route measures the same line, pauses and all")
    func storedRouteMatches() {
        let route = [
            RouteCoordinate(latitude: Self.start.latitude, longitude: Self.start.longitude),
            RouteCoordinate(latitude: Self.middle.latitude, longitude: Self.middle.longitude),
            RouteCoordinate(latitude: Self.end.latitude, longitude: Self.end.longitude, boundary: .paused),
        ]

        #expect(route.lengthMeters == RouteGeometry.lengthMeters(of: [Self.start, Self.middle, Self.end]))
    }
}
