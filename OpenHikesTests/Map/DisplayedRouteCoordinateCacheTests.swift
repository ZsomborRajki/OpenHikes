//
//  DisplayedRouteCoordinateCacheTests.swift
//  OpenHikesTests
//
//  The selected route's projection is kept per line, not per hike. *Edit
//  Route* keeps the hike's id and replaces its line, and mirroring delivers
//  that edit while the hike can be selected (#1228), so the cache has to
//  notice a write to `route` — and only that: an appearance write or a body
//  pass that changes nothing must still be answered from the cache.
//

import CoreLocation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

@Suite("Displayed route coordinate cache")
struct DisplayedRouteCoordinateCacheTests {
    private static let originalRoute = [
        RouteCoordinate(latitude: 47.63, longitude: 12.86),
        RouteCoordinate(latitude: 47.64, longitude: 12.87),
    ]

    /// Six points along one line, paused at the fourth when `paused` is set:
    /// the same geometry either way, so only the boundary tells them apart.
    private static func sixPoints(paused: Bool) -> [RouteCoordinate] {
        (0..<6).map { index in
            RouteCoordinate(
                latitude: 47.63,
                longitude: 12.86 + Double(index) * 0.001,
                boundary: paused && index == 3 ? .paused : nil
            )
        }
    }

    @Test("a line nobody wrote is answered from the cache")
    func unchangedLineIsKept() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()

        let first = cache.drawnRoute(for: hike)
        hike.tintHex = "#FF0000FF"
        hike.routeWidth = 9
        let second = cache.drawnRoute(for: hike)

        #expect(first.revision == second.revision, "an appearance write is not a new line")
        #expect(second.coordinates.count == 2)
    }

    /// The issue's own probe: a stored hike, its line replaced under the same
    /// id, asked for again without any change of selection.
    @Test("a new line for the selected hike is projected again")
    func replacedLineIsProjectedAgain() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()
        let before = cache.drawnRoute(for: hike)
        #expect(before.coordinates.first?.latitude == 47.63)

        hike.replaceRoute(with: [
            RouteCoordinate(latitude: 48, longitude: 13),
            RouteCoordinate(latitude: 48.01, longitude: 13.01),
        ])
        let after = cache.drawnRoute(for: hike)

        #expect(after.coordinates.first?.latitude == 48)
        #expect(after.revision != before.revision)
        #expect(cache.drawnRoute(for: hike).revision == after.revision, "…once, and then kept again")
    }

    /// A line can change without moving: a pause added at a point already on
    /// it changes where the line is cut and which leg is drawn dotted.
    @Test("a pause added to the selected hike's line reaches the drawn route")
    func pauseBoundaryEditIsProjectedAgain() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.sixPoints(paused: false))
        let cache = DisplayedRouteCoordinateCache()
        let before = try #require(DisplayedRoute.forSelection(hike, cache: cache))
        #expect(before.runs.pausedLegs.isEmpty)
        #expect(before.pausedSegments.isEmpty)

        hike.replaceRoute(with: Self.sixPoints(paused: true))
        let after = try #require(DisplayedRoute.forSelection(hike, cache: cache))

        #expect(after != before, "the map compares these, and must see a new line")
        #expect(after.runs.pausedLegs == [2])
        #expect(after.pausedSegments.count == 1)
    }

    /// What `OpenHikesView`'s body reads must include the line, or a write to
    /// it would re-run nothing and the cache would never be asked again.
    /// Projected once first, so the pass observed is one the cache answers:
    /// the body's ordinary pass, which reads no route value of its own.
    @Test("a new line invalidates whoever drew the old one")
    func routeWriteInvalidatesTheReader() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()
        _ = cache.drawnRoute(for: hike)
        let reader = ObservationCounter { _ = DisplayedRoute.forSelection(hike, cache: cache) }
        await reader.settle()

        hike.replaceRoute(with: Self.sixPoints(paused: false))
        await settleDelegateHop(until: "the route write reaches the reader") { reader.count == 1 }

        #expect(reader.count == 1)
        #expect(DisplayedRoute.forSelection(hike, cache: cache)?.coordinates.count == 6)
    }

    @Test("clearing the selection releases the cached route")
    func clearDropsCachedCoordinates() {
        let hike = Hike(title: "Cached", distanceMeters: 1000, route: Self.originalRoute)
        let cache = DisplayedRouteCoordinateCache()
        let before = cache.drawnRoute(for: hike)
        #expect(before.coordinates.count == 2)

        cache.clear()
        let refreshed = cache.drawnRoute(for: hike)
        #expect(refreshed.coordinates.count == 2)
        #expect(refreshed.revision != before.revision, "projected again, not handed back")
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
