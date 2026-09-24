//
//  MapCoordinatorTests+TrailDraftRouteChoices.swift
//  OpenHikesTests
//
//  The other routes a leg could take, and the time bubbles, against a real
//  `MKMapView` — see `MapTrailDraftRouteChoices.swift`.
//
//  The legs are given their alternatives by hand, through the draft's own
//  `beginRouting` and `apply`, because the maker these suites share has no
//  router and none may reach a network.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    private enum Valley {
        static let longitude: Double = -122.0300
        static let latitude: Double = 37.3350
        static let span: Double = 0.02
        static let south: Double = 37.3300
        static let north: Double = 37.3400
        /// Where the alternative bends out to, well clear of the drawn line.
        static let eastLongitude: Double = -122.0220
        /// What the router is made to answer with, in seconds and metres.
        static let drawnTime: TimeInterval = 600
        static let detourTime: TimeInterval = 900
        static let secondTime: TimeInterval = 300
        static let detourMeters: Double = 1900
    }

    private static func valley(_ latitude: Double, _ longitude: Double = Valley.longitude) -> RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }

    /// A two-stop trail whose one leg was answered with a detour east as an
    /// alternative, on a map framing both.
    private func routedWithAnAlternative(_ coordinator: MapView.Coordinator) async -> MKMapView {
        let map = makeMap(mapView(), coordinator)
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: Valley.latitude, longitude: Valley.longitude),
                span: MKCoordinateSpan(latitudeDelta: Valley.span, longitudeDelta: Valley.span)
            ),
            animated: false
        )
        trailMaker.setEditing(true)
        let south = Self.valley(Valley.south)
        let north = Self.valley(Valley.north)
        trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: south.latitude, longitude: south.longitude))
        trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: north.latitude, longitude: north.longitude))
        let ends = TrailLegEnds(start: south, end: north)
        let detour = [south, Self.valley(Valley.latitude, Valley.eastLongitude), north]
        trailMaker.draft.beginRouting([ends])
        trailMaker.draft.apply(
            TrailLegRoute(
                coordinates: [south, north],
                distanceMeters: ends.straightDistanceMeters,
                snap: .snapped,
                travelTime: Valley.drawnTime,
                alternatives: [
                    TrailLegPath(
                        coordinates: detour,
                        distanceMeters: Valley.detourMeters,
                        travelTime: Valley.detourTime
                    ),
                ]
            ),
            to: ends
        )
        await settle(until: "the alternative to reach the map") {
            coordinator.trailDraftRouteChoices.lines.count == 1
        }
        return map
    }

    @Test("a leg's alternative is drawn under it, and each has its time")
    func alternativesAndTimesAreDrawn() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await routedWithAnAlternative(coordinator)
        defer { detach(map) }

        let times = coordinator.trailDraftRouteChoices.times
        #expect(times.map { $0.choice?.alternativeIndex } == [nil, 0])
        #expect(times.map(\.travelTime) == [Valley.drawnTime, Valley.detourTime])
        let line = try #require(coordinator.trailDraftRouteChoices.lines.first)
        #expect(coordinator.mapView(map, rendererFor: line) is MKPolylineRenderer)
        #expect(coordinator.trailDraftRenderer(for: line, on: map) == nil, "an alternative is not the drawn leg")
        #endif
    }

    /// Apple Maps' gesture: a tap on the grey line draws it instead, and what
    /// was drawn becomes the grey one.
    @Test("a tap on an alternative chooses it")
    func tappingAnAlternativeChoosesIt() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await routedWithAnAlternative(coordinator)
        defer { detach(map) }
        let bend = CLLocationCoordinate2D(latitude: Valley.latitude, longitude: Valley.eastLongitude)

        #expect(coordinator.handleTrailDraftTap(at: map.convert(bend, toPointTo: map), in: map))

        let leg = try #require(trailMaker.draft.legs.first)
        #expect(leg.coordinates.contains(Self.valley(Valley.latitude, Valley.eastLongitude)))
        #expect(leg.travelTime == Valley.detourTime)
        #expect(leg.alternatives.first?.coordinates == [Self.valley(Valley.south), Self.valley(Valley.north)])
        #expect(trailMaker.selection == nil, "choosing a route drops no pin")
        #endif
    }

    /// The bubble on an alternative is the other way to choose it, and the one
    /// VoiceOver reaches — a line is not an accessibility element.
    @Test("a tap on an alternative's time chooses it")
    func tappingAnAlternativeTimeChoosesIt() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await routedWithAnAlternative(coordinator)
        defer { detach(map) }
        let bubble = try #require(coordinator.trailDraftRouteChoices.times.last)
        let view = coordinator.mapView(map, viewFor: bubble)

        #expect(view?.accessibilityLabel?.contains("Alternative") == true)
        #expect(coordinator.selectTrailDraftAnnotation(try #require(view), on: map))
        #expect(trailMaker.draft.legs.first?.travelTime == Valley.detourTime)
        #endif
    }

    /// Apple Maps draws one bubble per route, not per leg — and an
    /// alternative's bubble says what the whole trip takes with it taken, so
    /// it reads against the route's own bubble rather than against one leg.
    @Test("a route of several legs has one bubble, and an alternative's is the whole trip with it")
    func oneBubblePerRoute() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = await routedWithAnAlternative(coordinator)
        defer { detach(map) }
        // A second leg, north again, answered with a time of its own.
        let north = Self.valley(Valley.north)
        let further = Self.valley(Valley.north + 0.005)
        trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: further.latitude, longitude: further.longitude))
        let second = TrailLegEnds(start: north, end: further)
        trailMaker.draft.beginRouting([second])
        trailMaker.draft.apply(
            TrailLegRoute(
                coordinates: [north, further],
                distanceMeters: second.straightDistanceMeters,
                snap: .snapped,
                travelTime: Valley.secondTime
            ),
            to: second
        )
        await settle(until: "the second leg's route to reach the map") {
            coordinator.trailDraftRouteChoices.times.first?.travelTime == Valley.drawnTime + Valley.secondTime
        }

        let times = coordinator.trailDraftRouteChoices.times
        #expect(times.count(where: { $0.choice == nil }) == 1, "one bubble for the route drawn")
        #expect(times.first?.travelTime == Valley.drawnTime + Valley.secondTime)
        // Halfway along the longer leg, the first — not halfway along the
        // route, three quarters of the way up it, where the bubble is that much
        // nearer the middle stop's pin and loses the collision with it.
        let route = try #require(times.first { $0.choice == nil })
        #expect(abs(route.coordinate.latitude - Valley.latitude) < 1e-6)
        let alternative = try #require(times.first { $0.choice != nil })
        #expect(alternative.travelTime == Valley.detourTime + Valley.secondTime)
        #endif
    }

    /// The heights land about two seconds after the drawing settles, from a
    /// task nobody is watching, and no leg or stop moves when they do — so
    /// the only thing that can redraw the bubble is the map's registration
    /// reading the climb. See ``TrailDraftDrawnState``.
    @Test("a hiking route's bubble takes the climb when its heights land")
    func theRouteBubbleCountsTheClimb() async throws {
        #if os(iOS)
        let maker = TrailDraftController(
            elevationSource: ClimbingHeightSource(),
            elevationPause: { _ in /* instant */ }
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(trailMaker: maker), coordinator)
        defer { detach(map) }
        maker.setEditing(true)
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: Valley.south, longitude: Valley.longitude))
        maker.appendWaypoint(at: CLLocationCoordinate2D(latitude: Valley.north, longitude: Valley.longitude))

        await settle(until: "the climbing time to reach the route's bubble") {
            maker.elevation.summary != nil
                && coordinator.trailDraftRouteChoices.times.first?.travelTime
                == maker.draft.travelTime(climb: maker.elevation.summary)
        }

        let bubble = try #require(coordinator.trailDraftRouteChoices.times.first { $0.choice == nil })
        #expect(maker.draft.travelMode == .hiking)
        #expect(bubble.travelTime > maker.draft.travelTime * 2, "a 600 m climb dominates a 1.1 km line")
        #endif
    }

    @Test("a leg still being routed has no time to show")
    func aRoutingLegHasNoTime() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        trailMaker.setEditing(true)
        trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: Valley.south, longitude: Valley.longitude))
        trailMaker.appendWaypoint(at: CLLocationCoordinate2D(latitude: Valley.north, longitude: Valley.longitude))
        await settle(until: "the freehand leg's time to be drawn") {
            coordinator.trailDraftRouteChoices.times.count == 1
        }

        trailMaker.draft.beginRouting(trailMaker.draft.legs.map(\.ends))

        await settle(until: "the time to be withdrawn") {
            coordinator.trailDraftRouteChoices.times.isEmpty
        }
        #endif
    }
}

/// Heights that climb 600 m from the first point asked about to the last, so
/// a line of any shape has a climb far past the deadband.
nonisolated private final class ClimbingHeightSource: CuratedElevationSourcing {
    static let climbMeters = 600.0

    @concurrent
    func heights(at coordinates: [CLLocationCoordinate2D]) async -> [Double] {
        let steps = Double(max(1, coordinates.count - 1))
        return coordinates.indices.map { index in 1000 + Self.climbMeters * Double(index) / steps }
    }
}
