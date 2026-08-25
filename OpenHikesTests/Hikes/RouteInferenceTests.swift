//
//  RouteInferenceTests.swift
//  OpenHikesTests
//
//  Which parts of a saved route the app is entitled to present as measured.
//

import CoreLocation
@testable import OpenHikes
import Testing

@Suite("Route inference")
struct RouteInferenceTests {
    private func measured(
        _ latitude: Double,
        _ longitude: Double
    ) -> RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }

    private func inferred(
        _ latitude: Double,
        _ longitude: Double
    ) -> RouteCoordinate {
        RouteCoordinate(
            latitude: latitude,
            longitude: longitude,
            provenance: .inferred
        )
    }

    @Test("a fully measured route reports nothing inferred")
    func measuredRouteHasNoInference() {
        let route = [
            measured(47.63, 12.86),
            measured(47.64, 12.87),
            measured(47.65, 12.88),
        ]

        #expect(!route.containsInferredGeometry)
        #expect(route.inferredSegments.isEmpty)
        #expect(route.inferredDistanceMeters == 0)
    }

    @Test("an inferred run starts at the last measured position")
    func inferredRunIncludesItsAnchor() throws {
        let route = [
            measured(47.63, 12.86),
            measured(47.64, 12.86),
            inferred(47.65, 12.86),
            inferred(47.66, 12.86),
            measured(47.67, 12.86),
        ]

        let segments = route.inferredSegments
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        // Three points, not two: the drawn stretch has to meet the measured
        // line it leaves, so the last observed position anchors it.
        #expect(segment.count == 3)
        #expect(segment.first?.latitude == 47.64)
        #expect(segment.last?.latitude == 47.66)
    }

    @Test("separate gaps stay separate stretches")
    func multipleGapsAreNotJoined() {
        let route = [
            measured(47.63, 12.86),
            inferred(47.64, 12.86),
            measured(47.65, 12.86),
            measured(47.66, 12.86),
            inferred(47.67, 12.86),
        ]

        let segments = route.inferredSegments
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.count == 2 })
        #expect(route.containsInferredGeometry)
    }

    @Test("a route that is inferred from its second point is still anchored")
    func gapImmediatelyAfterTheStart() throws {
        let route = [
            measured(47.63, 12.86),
            inferred(47.64, 12.86),
        ]

        let segment = try #require(route.inferredSegments.first)
        #expect(segment.count == 2)
        #expect(segment.first?.latitude == 47.63)
    }

    @Test("a lone point cannot be inferred geometry")
    func singlePointHasNoSegments() {
        let route = [inferred(47.63, 12.86)]

        #expect(route.inferredSegments.isEmpty)
        #expect(route.inferredDistanceMeters == 0)
        #expect(!route.containsInferredGeometry)
    }

    @Test("inferred distance measures only the unobserved segments")
    func inferredDistanceCountsOnlyItsOwnSegments() {
        let route = [
            measured(47.63, 12.86),
            measured(47.64, 12.86),
            inferred(47.65, 12.86),
        ]

        let expected = RouteGeometry.distanceMeters(
            from: CLLocationCoordinate2D(latitude: 47.64, longitude: 12.86),
            to: CLLocationCoordinate2D(latitude: 47.65, longitude: 12.86)
        )
        #expect(abs(route.inferredDistanceMeters - expected) < 0.001)
    }

    @Test("statistics report the inferred share of a route's length")
    func statisticsSurfaceInferredDistance() throws {
        let route = [
            measured(47.63, 12.86),
            measured(47.64, 12.86),
            inferred(47.65, 12.86),
        ]

        let statistics = HikeRouteStatistics(
            distanceMeters: route.inferredDistanceMeters * 3,
            route: route
        )

        let inferredDistance = try #require(statistics.inferredDistance)
        #expect(
            abs(inferredDistance.value - route.inferredDistanceMeters) < 0.001
        )
    }

    @Test("a measured route reports no inferred distance at all")
    func statisticsOmitInferredDistanceWhenMeasured() {
        let route = [
            measured(47.63, 12.86),
            measured(47.64, 12.86),
        ]

        let statistics = HikeRouteStatistics(distanceMeters: 1113, route: route)

        #expect(statistics.inferredDistance == nil)
    }

    @Test("a drawn route carries its inferred stretches to the map")
    func displayedRouteCarriesInferredSegments() throws {
        let hike = Hike(
            title: "Spotty",
            distanceMeters: 3000,
            route: [
                measured(47.63, 12.86),
                inferred(47.65, 12.86),
                measured(47.66, 12.86),
            ]
        )

        let drawn = try #require(
            DisplayedRoute.forSelection(
                hike,
                cache: DisplayedRouteCoordinateCache()
            )
        )

        #expect(drawn.coordinates.count == 3)
        #expect(drawn.inferredSegments.count == 1)
        #expect(drawn.inferredSegments.first?.count == 2)
    }

    @Test("provenance survives a round trip through a recording point")
    func recordingPointCarriesProvenance() {
        var point = RecordingPoint(
            latitude: 47.63,
            longitude: 12.86,
            timestamp: .now,
            horizontalAccuracy: 8
        )
        #expect(point.routeCoordinate.provenance == nil)

        point.flags.insert(.inferred)
        #expect(point.routeCoordinate.isInferred)
    }
}
