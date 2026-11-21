//
//  MapCoordinatorTests+RouteStretch.swift
//  OpenHikesTests
//
//  *Edit Route*'s half of the map beyond the two cuts: the stretch the
//  handles pick out is drawn dashed between them while the covers gray
//  nothing, and a finger held on the line takes hold of a stretch of it and
//  redraws it through where it is lifted. See `MapRouteTrim+Stretch.swift`.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

extension MapCoordinatorTests {
    /// A map with the ridge route drawn and on screen, and a visit to *Edit
    /// Route* on it.
    private func editing(
        _ coordinator: MapView.Coordinator
    ) async -> (map: MKMapView, session: RouteTrimSession) {
        let route = Fixture.ridgeRoute
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

    /// The spot on screen `fraction` of the way along the line.
    private func point(_ fraction: Double, along session: RouteTrimSession, on map: MKMapView) throws -> CGPoint {
        let line = try #require(session.line)
        let coordinate = try #require(line.profile.coordinate(atDistance: line.totalMeters * fraction))
        return map.convert(coordinate, toPointTo: map)
    }

    @Test("a stretch picked out is drawn dashed between the handles, and the covers gray nothing")
    func aStretchIsPickedOutOnTheMap() async throws {
        let coordinator = MapView.Coordinator()
        let (map, session) = await editing(coordinator)
        defer { detach(map) }
        session.move(.end, to: session.totalMeters * 0.9)
        #expect(coordinator.routeTrimMap.stretch.picked == nil)

        await session.beginStretch()
        await settle(until: "the stretch to be picked out on the map") {
            coordinator.routeTrimMap.stretch.picked != nil
        }

        let picked = try #require(coordinator.routeTrimMap.stretch.picked)
        #expect(map.overlays.contains { $0 === picked })
        let renderer = try #require(coordinator.mapView(map, rendererFor: picked) as? MKPolylineRenderer)
        #expect(renderer.lineDashPattern == [3, 5])
        #expect(renderer.strokeStart.isApproximatelyEqual(to: 1.0 / 3, absoluteTolerance: 0.02))
        #expect(renderer.strokeEnd.isApproximatelyEqual(to: 2.0 / 3, absoluteTolerance: 0.02))
        let trailing = try #require(coordinator.routeTrimMap.trailingCover)
        let cover = try #require(coordinator.mapView(map, rendererFor: trailing) as? MKPolylineRenderer)
        #expect(cover.alpha == 0, "the handles cut nothing while they pick a stretch out")

        session.move(.end, to: session.totalMeters * 0.8)
        await settle(until: "the stretch to follow its handle") {
            (coordinator.routeTrimMap.stretch.pickedRenderer?.strokeEnd ?? 0) > 0.75
        }
        #expect(coordinator.routeTrimMap.stretch.pickedRenderer?.strokeEnd.isApproximatelyEqual(
            to: 0.8,
            absoluteTolerance: 0.02
        ) == true)

        await session.endStretch()
        await settle(until: "the stretch to be let go") { coordinator.routeTrimMap.stretch.picked == nil }
        #expect(!map.overlays.contains { $0 === picked })
        #expect(session.endMeters.isApproximatelyEqual(to: session.totalMeters * 0.9, absoluteTolerance: 1))
    }

    @Test("a finger held on the line takes hold of a stretch, and lifting it elsewhere redraws it through there")
    func pullingTheLine() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let (map, session) = await editing(coordinator)
        defer { detach(map) }
        let held = try point(0.5, along: session, on: map)
        #expect(coordinator.routePullStretch(at: held, in: map) != nil)

        #expect(coordinator.beginRoutePull(at: held, in: map))

        let stretch = try #require(coordinator.routeTrimMap.stretch.pulled)
        #expect(stretch.contains(session.totalMeters / 2))
        #expect(stretch.lowerBound > 0)
        #expect(stretch.upperBound < session.totalMeters)
        let cover = try #require(coordinator.routeTrimMap.stretch.pullCover)
        let band = try #require(coordinator.routeTrimMap.stretch.pullBand)
        #expect(map.overlays.contains { $0 === cover })
        #expect(map.overlays.contains { $0 === band })
        #expect(band.pointCount == 3)
        #expect(!map.isScrollEnabled, "the map stops moving under a line that is being pulled")

        let lifted = CGPoint(x: held.x + 60, y: held.y)
        coordinator.moveRoutePull(to: lifted, in: map)
        let moved = try #require(coordinator.routeTrimMap.stretch.pullBand)
        #expect(moved !== band)
        #expect(!map.overlays.contains { $0 === band })

        coordinator.endRoutePull(at: lifted, in: map)
        #expect(map.isScrollEnabled)
        await settle(until: "the stretch to be redrawn") { session.steps.count == 1 }

        guard case .replace(let range, let path)? = session.steps.first else {
            Issue.record("a pull should be a stretch replaced")
            return
        }
        #expect(range == stretch)
        #expect(path.count == 1, "with nobody to ask for a path, straight through where the finger was lifted")
        await settle(until: "the pull to leave the map") { coordinator.routeTrimMap.stretch.pullCover == nil }
        #expect(!map.overlays.contains { $0 === cover || $0 === moved })
        #expect(coordinator.routeTrimMap.stretch.pulled == nil)
        #endif
    }

    @Test("a finger lifted where it came down, off the line or on a handle asks for nothing")
    func pullsThatAreNone() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let (map, session) = await editing(coordinator)
        defer { detach(map) }
        let held = try point(0.5, along: session, on: map)

        #expect(coordinator.beginRoutePull(at: held, in: map))
        coordinator.endRoutePull(at: held, in: map)
        #expect(coordinator.routeTrimMap.stretch.pullCover == nil)
        #expect(coordinator.routeTrimMap.stretch.pullBand == nil)
        #expect(map.isScrollEnabled)
        #expect(session.steps.isEmpty)

        let end = try #require(coordinator.routeTrimMap.endHandle)
        let onTheHandle = map.convert(end.coordinate, toPointTo: map)
        #expect(coordinator.routePullStretch(at: onTheHandle, in: map) == nil, "a handle is a handle")
        #expect(!coordinator.beginRoutePull(at: onTheHandle, in: map))
        let offTheLine = CGPoint(x: held.x + 120, y: held.y)
        #expect(coordinator.routePullStretch(at: offTheLine, in: map) == nil)

        await session.beginStretch()
        #expect(
            coordinator.routePullStretch(at: held, in: map) == nil,
            "while the handles pick a stretch out, the line is not pulled"
        )
        #endif
    }
}
