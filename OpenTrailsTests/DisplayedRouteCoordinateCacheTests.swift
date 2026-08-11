//
//  DisplayedRouteCoordinateCacheTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Testing
@testable import OpenTrails

@MainActor
@Suite("Displayed route coordinate cache")
struct DisplayedRouteCoordinateCacheTests {
    @Test("clearing the selection releases the cached route")
    func clearDropsCachedCoordinates() {
        let originalRoute = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.64, longitude: 12.87)
        ]
        let hike = Hike(title: "Cached", distanceMeters: 1_000, route: originalRoute)
        let cache = DisplayedRouteCoordinateCache()

        #expect(cache.coordinates(for: hike).count == 2)

        hike.route = [RouteCoordinate(latitude: 48, longitude: 13)]
        #expect(cache.coordinates(for: hike).count == 2, "the selected hike reuses its immutable route projection")

        cache.clear()
        let refreshed = cache.coordinates(for: hike)
        #expect(refreshed.count == 1)
        #expect(refreshed[0].latitude == 48)
    }
}
