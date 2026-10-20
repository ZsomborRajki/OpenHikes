//
//  PlausibleElevationTests.swift
//  OpenHikesTests
//

import CoreLocation
@testable import OpenHikesData
import Testing

@Suite("Plausible elevations")
struct PlausibleElevationTests {
    /// 120 points walking north about 55 m apart, climbing a metre each.
    private static func walk(
        heights: [Double?] = (0..<120).map { 1000 + Double($0) }
    ) -> [RouteCoordinate] {
        heights.indices.map { step in
            RouteCoordinate(
                latitude: 47.55 + Double(step) * 0.0005,
                longitude: 12.86,
                elevation: heights[step]
            )
        }
    }

    @Test(
        "A void marker or an impossible height is absent",
        arguments: [-9999, -32_768, 99_999, -501, 9001, Double.nan, .infinity, -.infinity]
    )
    func impossibleHeightsAreRefused(height: Double) {
        #expect(PlausibleElevation.validated(height) == nil)
    }

    @Test("Heights at the ends of the range pass through unchanged", arguments: [-430.0, 0, 8849, -500, 9000])
    func realHeightsPass(height: Double) {
        #expect(PlausibleElevation.validated(height) == height)
    }

    @Test("A stray zero on a walk at 1 000 m is a spike")
    func strayZeroIsASpike() {
        var route = Self.walk()
        route[60].elevation = 0

        #expect(PlausibleElevation.spikes(in: route.map { ($0.clCoordinate, $0.elevation) }) == [60])
        let despiked = PlausibleElevation.despiked(route)
        #expect(despiked[60].elevation == nil)
        #expect(despiked[60].latitude == route[60].latitude)
        #expect(despiked[59].elevation == 1059)
        #expect(despiked[61].elevation == 1061)
    }

    @Test("A spike is judged against the nearest heights, past points that have none")
    func neighboursSkipMissingHeights() {
        var route = Self.walk()
        route[59].elevation = nil
        route[60].elevation = 0
        route[61].elevation = nil

        #expect(PlausibleElevation.despiked(route)[60].elevation == nil)
    }

    /// The guard that keeps a planned route over a summit: stops a kilometre
    /// either side of a top 500 m above them is a steep path, not a
    /// placeholder.
    @Test("A real summit between sparse stops is kept")
    func sparseSummitIsKept() {
        let route = [
            RouteCoordinate(latitude: 47.55, longitude: 12.86, elevation: 1000),
            RouteCoordinate(latitude: 47.56, longitude: 12.86, elevation: 1500),
            RouteCoordinate(latitude: 47.57, longitude: 12.86, elevation: 1050),
        ]

        #expect(PlausibleElevation.despiked(route) == route)
    }

    @Test("A step that stays up is not a spike")
    func stepIsKept() {
        let heights: [Double?] = (0..<120).map { $0 < 60 ? 1000 : 1150 }
        let route = Self.walk(heights: heights)

        #expect(PlausibleElevation.despiked(route) == route)
    }

    @Test("Two placeholders in a row vouch for each other, and the ends are left alone")
    func pairsAndEndsAreKept() {
        var route = Self.walk()
        route[0].elevation = 0
        route[60].elevation = 0
        route[61].elevation = 0
        route[119].elevation = 0

        #expect(PlausibleElevation.despiked(route) == route)
    }
}
