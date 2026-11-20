//
//  MapCoordinatorTests+RouteTrim.swift
//  OpenHikesTests
//
//  *Edit Route*'s half of the map: the two handles and the two covers appear
//  with a visit and go with it, follow the cuts, and a handle under a finger
//  slides along the line and takes the map's scrolling for as long as it is
//  held. See `MapRouteTrim.swift`.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

extension MapCoordinatorTests {
    /// A map with `route` drawn and on screen, and a visit to *Edit Route* on
    /// it.
    private func trimming(
        _ coordinator: MapView.Coordinator,
        route: [RouteCoordinate] = Fixture.ridgeRoute
    ) async -> (map: MKMapView, session: RouteTrimSession) {
        let view = mapView(route: Self.route(coordinates: route))
        let map = makeMap(view, coordinator)
        view.update(map, coordinator)
        // A map under test is in no window, so nothing frames the line for it.
        var points = Fixture.coordinates(route)
        let bounds = MKPolyline(coordinates: &points, count: points.count).boundingMapRect
        var region = MKCoordinateRegion(bounds)
        region.span.latitudeDelta *= 2
        region.span.longitudeDelta = max(region.span.longitudeDelta * 2, region.span.latitudeDelta)
        map.setRegion(region, animated: false)
        let session = RouteTrimSession()
        await session.load(route)
        session.show(on: routeTrim)
        await settle(until: "the trim's handles to be on the map") {
            coordinator.routeTrimMap.endHandle != nil
        }
        return (map, session)
    }

    @Test("a visit puts a handle on each end and a cover for each, and its end takes them off")
    func aTrimIsDrawnForItsVisit() async throws {
        let coordinator = MapView.Coordinator()
        let (map, session) = await trimming(coordinator)
        defer { detach(map) }

        let start = try #require(coordinator.routeTrimMap.startHandle)
        let end = try #require(coordinator.routeTrimMap.endHandle)
        let first = try #require(Fixture.ridgeRoute.first)
        let last = try #require(Fixture.ridgeRoute.last)
        #expect(start.coordinate.latitude == first.latitude)
        #expect(end.coordinate.latitude == last.latitude)
        #expect(map.annotations.contains { $0 === start })
        let leading = try #require(coordinator.routeTrimMap.leadingCover)
        let trailing = try #require(coordinator.routeTrimMap.trailingCover)
        #expect(map.overlays.contains { $0 === leading })
        #expect(map.overlays.contains { $0 === trailing })
        #expect(leading.pointCount == Fixture.ridgeRoute.count)

        session.end()
        await settle(until: "the trim to leave the map") { coordinator.routeTrimMap.endHandle == nil }

        #expect(!map.annotations.contains { $0 is RouteTrimHandleAnnotation })
        #expect(!map.overlays.contains { $0 === leading || $0 === trailing })
        #expect(coordinator.routeTrimMap.session == nil)
    }

    @Test("a cover is stroked from the line's end as far as its cut, and hidden until there is one")
    func theCoversFollowTheCuts() async throws {
        let coordinator = MapView.Coordinator()
        let (map, session) = await trimming(coordinator)
        defer { detach(map) }
        let leading = try #require(coordinator.routeTrimMap.leadingCover)
        let trailing = try #require(coordinator.routeTrimMap.trailingCover)
        let before = try #require(coordinator.mapView(map, rendererFor: leading) as? MKPolylineRenderer)
        let after = try #require(coordinator.mapView(map, rendererFor: trailing) as? MKPolylineRenderer)
        #expect(before.alpha == 0, "nothing is cut off the start")
        #expect(after.alpha == 0)

        session.move(.end, to: session.totalMeters * 0.6)
        await settle(until: "the trailing cover to follow its cut") {
            (coordinator.routeTrimMap.trailingRenderer?.strokeStart ?? 1) < 1
        }

        // Whichever renderer the map holds by now: MapKit may have asked for
        // its own since.
        let drawn = try #require(coordinator.routeTrimMap.trailingRenderer)
        #expect(drawn.strokeStart.isApproximatelyEqual(to: 0.6, absoluteTolerance: 0.01))
        #expect(drawn.strokeEnd == 1)
        #expect(drawn.alpha == 1)
        #expect(coordinator.routeTrimMap.leadingRenderer?.alpha == 0)
        let end = try #require(coordinator.routeTrimMap.endHandle)
        let cut = try #require(session.line).endSpot(at: session.endMeters)
        #expect(end.coordinate.latitude == cut.coordinate.latitude)
    }

    @Test("a press on a handle takes hold of it, and a press elsewhere of nothing")
    func pressingAHandle() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let (map, _) = await trimming(coordinator)
        defer { detach(map) }
        let start = try #require(coordinator.routeTrimMap.startHandle)
        let end = try #require(coordinator.routeTrimMap.endHandle)

        let onTheStart = map.convert(start.coordinate, toPointTo: map)
        let onTheEnd = map.convert(end.coordinate, toPointTo: map)
        #expect(coordinator.routeTrimHandle(at: onTheStart, in: map) == .start)
        #expect(coordinator.routeTrimHandle(at: onTheEnd, in: map) == .end)
        let between = CGPoint(x: (onTheStart.x + onTheEnd.x) / 2, y: (onTheStart.y + onTheEnd.y) / 2)
        #expect(coordinator.routeTrimHandle(at: between, in: map) == nil)
        #expect(!coordinator.beginRouteTrimDrag(at: between, in: map))
        #expect(map.isScrollEnabled)
        #endif
    }

    @Test("dragging a handle slides its cut along the line and gives the map back after")
    func draggingAHandle() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let (map, session) = await trimming(coordinator)
        defer { detach(map) }
        let end = try #require(coordinator.routeTrimMap.endHandle)
        let total = session.totalMeters

        #expect(coordinator.beginRouteTrimDrag(at: map.convert(end.coordinate, toPointTo: map), in: map))
        #expect(!map.isScrollEnabled, "the map stops moving under a handle that is moving over it")

        // To the line's fourth point, which is three fifths of the way along.
        let target = Fixture.ridgeRoute[3].clCoordinate
        coordinator.moveRouteTrimDrag(to: map.convert(target, toPointTo: map), in: map)

        #expect(session.endMeters.isApproximatelyEqual(to: total * 0.6, absoluteTolerance: total * 0.02))
        #expect(session.startMeters == 0)
        #expect(end.coordinate.latitude.isApproximatelyEqual(to: target.latitude, absoluteTolerance: 0.0001))

        coordinator.releaseRouteTrimDrag(on: map)
        #expect(map.isScrollEnabled)
        #expect(coordinator.routeTrimMap.held == nil)
        #endif
    }

    @Test("where the handles stand on one spot, a press takes the end")
    func aLoopsHandles() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let (map, _) = await trimming(coordinator, route: Fixture.loopRoute)
        defer { detach(map) }
        let start = try #require(coordinator.routeTrimMap.startHandle)

        let onBoth = map.convert(start.coordinate, toPointTo: map)

        #expect(coordinator.routeTrimHandle(at: onBoth, in: map) == .end)
        #endif
    }
}
