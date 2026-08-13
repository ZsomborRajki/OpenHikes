//
//  DisplayedRouteCoordinateCacheTests.swift
//  OpenTrailsTests
//

import CoreLocation
@testable import OpenTrails
import Testing

@Suite("Displayed route coordinate cache")
struct DisplayedRouteCoordinateCacheTests {
    @Test("clearing the selection releases the cached route")
    func clearDropsCachedCoordinates() {
        let originalRoute = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.64, longitude: 12.87),
        ]
        let hike = Hike(title: "Cached", distanceMeters: 1000, route: originalRoute)
        let cache = DisplayedRouteCoordinateCache()

        #expect(cache.coordinates(for: hike).count == 2)

        hike.route = [RouteCoordinate(latitude: 48, longitude: 13)]
        #expect(cache.coordinates(for: hike).count == 2, "the selected hike reuses its immutable route projection")

        cache.clear()
        let refreshed = cache.coordinates(for: hike)
        #expect(refreshed.count == 1)
        #expect(refreshed[0].latitude == 48)
    }

    @Test("the recording screen never draws the previously selected finished route")
    func recordingPresentationSuppressesFinishedRoute() {
        let hike = Hike(
            title: "Imported Track",
            distanceMeters: 1000,
            route: Fixture.ridgeRoute
        )
        let cache = DisplayedRouteCoordinateCache()

        #expect(
            DisplayedRoute.forSelection(
                hike,
                cache: cache,
                recordingPresented: true
            ) == nil
        )
        #expect(
            DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count
                == Fixture.ridgeRoute.count
        )
    }

    @Test("an active recording draft is not treated as a finished route")
    func recordingDraftIsSuppressedUntilFinalized() {
        let hike = Hike(
            title: "Morning Hike",
            distanceMeters: 0,
            route: Fixture.ridgeRoute,
            isRecording: true
        )
        let cache = DisplayedRouteCoordinateCache()

        #expect(DisplayedRoute.forSelection(hike, cache: cache) == nil)

        hike.isRecording = false
        #expect(
            DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count
                == Fixture.ridgeRoute.count
        )
    }
}
