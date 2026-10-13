//
//  MapCoordinatorTests+RevealSpot.swift
//  OpenHikesTests
//
//  ``MapController/reveal(_:)`` against a real `MKMapView`: a spot the hiker
//  can already see leaves the camera alone, and one the sheet covers is slid
//  into the part of the map nothing is drawn over at the zoom the map is at.
//  What a Commons photograph's screen asks for when it opens — see
//  ``CommonsPhotoView``.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

extension MapCoordinatorTests {
    @Test("revealing a spot already in view moves nothing")
    func revealInViewMovesNothing() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        let before = map.centerCoordinate
        let controller = MapController()
        controller.reveal(map.convert(coordinator.focusPoint(in: map), toCoordinateFrom: map))

        coordinator.applyRegionRequest(of: controller, on: map)

        #expect(map.centerCoordinate.latitude.isApproximatelyEqual(to: before.latitude, absoluteTolerance: 1e-9))
        #expect(map.centerCoordinate.longitude.isApproximatelyEqual(to: before.longitude, absoluteTolerance: 1e-9))
        #endif
    }

    @Test("revealing a spot under the sheet slides it into view at the same zoom")
    func revealUnderSheetSlides() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        // A valley's width, as the *Community* tab shows one. The fixture's
        // own framing is ten degrees across, where MapKit keeps a slide's
        // span in degrees rather than its zoom.
        map.setRegion(
            MKCoordinateRegion(center: map.centerCoordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000),
            animated: false
        )
        let width = map.visibleMapRect.size.width
        let covered = map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.height * 0.8), toCoordinateFrom: map)
        let controller = MapController()
        controller.reveal(covered)

        coordinator.applyRegionRequest(of: controller, on: map)

        let area = coordinator.focusArea(in: map)
        #expect(area.contains(map.convert(covered, toPointTo: map)), "out from under the sheet")
        // In map points, which a slide at one zoom leaves alone; a span in
        // degrees of latitude changes with the latitude it is centred on.
        #expect(
            map.visibleMapRect.size.width.isApproximatelyEqual(to: width, relativeTolerance: 0.01),
            "at the zoom it was at: \(map.visibleMapRect.size.width) against \(width)"
        )
        #endif
    }

    @Test("a reveal and a region replace each other as the last request")
    func revealAndRegionReplaceEachOther() {
        let controller = MapController()
        let spot = CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0)

        controller.show(MKCoordinateRegion(center: spot, latitudinalMeters: 500, longitudinalMeters: 500))
        controller.reveal(spot)
        #expect(controller.region == nil)
        #expect(controller.revealedSpot?.latitude == spot.latitude)

        controller.showPhotoSpot(spot)
        #expect(controller.revealedSpot == nil)
        #expect(controller.region != nil)
        #expect(controller.showRegionRequest == 3)
    }
}
