//
//  DisplayedRouteCoordinateCacheTests.swift
//  OpenHikesTests
//
//  The selected route's projection is made off the main actor, from the
//  selection's change handler, and the root body only reads what has landed
//  (#1232). Made in the body, a long trail's first pass mapped and walked
//  every point on the main actor.
//
//  Where the projection runs is asserted through the cache's build seam, as
//  `PinnedTrailReadTests` asserts its read through the fetch: the build
//  records the thread it ran on.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@Suite("Displayed route coordinate cache")
struct DisplayedRouteCoordinateCacheTests {
    /// Which threads the projection ran on, one entry per call.
    nonisolated final class BuildLog: Sendable {
        private let threads = Mutex<[Bool]>([])

        var ranOnMainThread: [Bool] { threads.withLock { $0 } }

        func build(_ route: [RouteCoordinate]) -> DisplayedRouteCoordinateCache.DrawnRoute {
            threads.withLock { $0.append(Thread.isMainThread) }
            return DisplayedRouteCoordinateCache.DrawnRoute(route: route)
        }
    }

    /// The caller is the main actor itself, so a projection that stays on its
    /// caller's executor fails.
    @Test("a selected route is projected off the main thread")
    func theProjectionRunsOffTheMainThread() async {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let hike = Hike(title: "Ridge", distanceMeters: 1000, route: Fixture.ridgeRoute)
        let log = BuildLog()
        let cache = DisplayedRouteCoordinateCache(build: log.build)

        cache.prepare(for: hike)
        await cache.preparation?.value

        #expect(log.ranOnMainThread == [false])
        let drawn = DisplayedRoute.forSelection(hike, cache: cache)
        #expect(drawn?.id == hike.id)
        #expect(drawn?.coordinates.map(\.latitude) == Fixture.coordinates(Fixture.ridgeRoute).map(\.latitude))
    }

    /// The body reads only what has landed, so it never pays for a projection
    /// itself, and it hears the landing so the map is handed the line.
    @Test("the root view draws nothing until the projection lands, then hears it once")
    func theBodyWaitsForTheProjection() async {
        let hike = Hike(title: "Ridge", distanceMeters: 1000, route: Fixture.ridgeRoute)
        let log = BuildLog()
        let cache = DisplayedRouteCoordinateCache(build: log.build)
        let rootView = ObservationCounter { _ = DisplayedRoute.forSelection(hike, cache: cache) }

        cache.prepare(for: hike)
        #expect(DisplayedRoute.forSelection(hike, cache: cache) == nil, "the body must not project it in place")
        await cache.preparation?.value
        await rootView.settle()

        #expect(rootView.count == 1)
        #expect(DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count == Fixture.ridgeRoute.count)

        cache.prepare(for: hike)
        #expect(log.ranOnMainThread.count == 1, "the same selection again projects nothing")
    }

    /// A deselection made while the projection was in flight: the answer
    /// that lands afterwards belongs to a selection that is gone.
    @Test("a projection for a selection that moved on is dropped")
    func aStaleProjectionIsDropped() async {
        let hike = Hike(title: "Ridge", distanceMeters: 1000, route: Fixture.ridgeRoute)
        let cache = DisplayedRouteCoordinateCache()

        cache.prepare(for: hike)
        let stale = cache.preparation
        cache.prepare(for: nil)
        await stale?.value

        #expect(DisplayedRoute.forSelection(hike, cache: cache) == nil)
    }

    @Test("clearing the selection releases the cached route")
    func clearDropsCachedCoordinates() async {
        let originalRoute = [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.64, longitude: 12.87),
        ]
        let hike = Hike(title: "Cached", distanceMeters: 1000, route: originalRoute)
        let cache = DisplayedRouteCoordinateCache()

        cache.prepare(for: hike)
        await cache.preparation?.value
        #expect(cache.drawnRoute(for: hike)?.coordinates.count == 2)

        hike.replaceRoute(with: [RouteCoordinate(latitude: 48, longitude: 13)])
        cache.prepare(for: hike)
        await cache.preparation?.value
        #expect(
            cache.drawnRoute(for: hike)?.coordinates.count == 2,
            "the selected hike reuses its immutable route projection"
        )

        cache.prepare(for: nil)
        #expect(cache.drawnRoute(for: hike) == nil)
        cache.prepare(for: hike)
        await cache.preparation?.value
        let refreshed = cache.drawnRoute(for: hike)?.coordinates
        #expect(refreshed?.count == 1)
        #expect(refreshed?.first?.latitude == 48)
    }

    @Test("the recording screen never draws the previously selected finished route")
    func recordingPresentationSuppressesFinishedRoute() async {
        let hike = Hike(
            title: "Imported Track",
            distanceMeters: 1000,
            route: Fixture.ridgeRoute
        )
        let cache = DisplayedRouteCoordinateCache()
        cache.prepare(for: hike)
        await cache.preparation?.value

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
    func recordingDraftIsSuppressedUntilFinalized() async {
        let hike = Hike(
            title: "Morning Hike",
            distanceMeters: 0,
            route: Fixture.ridgeRoute,
            isRecording: true
        )
        let cache = DisplayedRouteCoordinateCache()

        cache.prepare(for: hike)
        #expect(cache.preparation == nil, "a draft's line is the recorder's to draw")
        #expect(DisplayedRoute.forSelection(hike, cache: cache) == nil)

        hike.isRecording = false
        cache.prepare(for: hike)
        await cache.preparation?.value
        #expect(
            DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count
                == Fixture.ridgeRoute.count
        )
    }
}
