//
//  MapCoordinatorTests+PausedRoute.swift
//  OpenHikesTests
//
//  What the map hands the route's renderer for a paused route (#1034): the
//  walked runs to stroke and the paused legs to leave empty, while the
//  overlay stays the whole route, so the fit, the tap and the coloured
//  stretches still see one line. `DirectionalPolylineRendererTests+Pauses`
//  covers what the renderer draws with them.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

extension MapCoordinatorTests {
    /// Six points with a pause arriving at the fourth: two walked runs of
    /// three points each, with the drive between them.
    private static func pausedRoute() -> DisplayedRoute {
        let coordinates = (0..<6).map { CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86 + Double($0) * 0.001) }
        return DisplayedRoute(
            id: UUID(),
            coordinates: coordinates,
            runs: TrailRuns(pointCount: coordinates.count, pauseIndices: [3])
        )
    }

    @Test("a paused route's renderer is handed its walked runs and its paused legs")
    func pausedRouteIsCut() throws {
        let coordinator = MapView.Coordinator()
        let route = Self.pausedRoute()
        let view = mapView(route: route)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let line = try #require(coordinator.routeOverlay)
        #expect(line.pointCount == 6, "the overlay is still the whole route")
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(renderer.pausedLegs == [2])
        #expect(renderer.runs.map(\.pointCount) == [3, 3])
    }

    /// The cut comes from the selected hike's own route: a pause named on its
    /// first point opens nothing, and one arriving at its fourth cuts it there.
    @Test("a selected hike's pauses reach its renderer")
    func selectedHikesPausesCutItsLine() async throws {
        let route = (0..<6).map { index in
            RouteCoordinate(
                latitude: 47.63,
                longitude: 12.86 + Double(index) * 0.001,
                boundary: index == 0 || index == 3 ? .paused : nil
            )
        }
        let hike = Hike(title: "Two Halves", distanceMeters: 300, route: route)
        let drawn = try #require(await DisplayedRoute.prepared(for: hike))
        #expect(drawn.runs.pausedLegs == [2])

        let coordinator = MapView.Coordinator()
        let view = mapView(route: drawn)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(renderer.pausedLegs == [2])
        #expect(renderer.runs.map(\.pointCount) == [3, 3])
    }

    @Test("an unpaused route is stroked whole, and a paused one's cut goes with it")
    func cutIsClearedWithTheRoute() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        mapView(route: Self.pausedRoute()).update(map, coordinator)
        #expect(!coordinator.routePausedLegs.isEmpty)

        mapView(route: Self.route()).update(map, coordinator)
        let line = try #require(coordinator.routeOverlay)
        let renderer = try #require(coordinator.mapView(map, rendererFor: line) as? DirectionalPolylineRenderer)
        #expect(!renderer.isCut)
        #expect(renderer.runs.isEmpty)
        #expect(coordinator.routeRuns.isEmpty)
    }
}

// swiftlint:enable no_magic_numbers
