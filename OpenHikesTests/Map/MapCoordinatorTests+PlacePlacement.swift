//
//  MapCoordinatorTests+PlacePlacement.swift
//  OpenHikesTests
//
//  The pin *Add Place* puts a place down with, against a real `MKMapView`:
//  it stands still in the middle of the map the sheet leaves, the map is
//  moved once to put the spot under it, and wherever the map comes to rest
//  after that is where the place goes. See `MapPlacePlacement.swift`.
//
//  Every settle here is delivered by hand, as the search-region suite does:
//  a map that is not in a window is not guaranteed to say when it has
//  stopped, and what is asserted is what the coordinator does with a settle,
//  not when MapKit chose to report one.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing
#if canImport(UIKit)
import UIKit
#endif

extension MapCoordinatorTests {
    /// How close, in points, a coordinate has to land to the pin to count
    /// as under it — MapKit rounds its camera to the pixel.
    private static let pinTolerance: CGFloat = 1.5

    private enum OffCentre {
        static let x: CGFloat = 80
        static let y: CGFloat = 160
    }

    /// A spot well off the middle of the map, so putting it under the pin
    /// is a move rather than a coincidence.
    private func offCentreSpot(on map: MKMapView) -> HikePlaceSpot {
        HikePlaceSpot(map.convert(CGPoint(x: OffCentre.x, y: OffCentre.y), toCoordinateFrom: map))
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    /// Puts a form's placeholder up and waits until the map has its spot
    /// under the pin.
    private func placePin(
        at spot: HikePlaceSpot,
        on map: MKMapView,
        _ coordinator: MapView.Coordinator
    ) async -> Int {
        let token = placePins.attach([], placeholder: HikePlaceDraft().placeholder(at: spot))
        await settle(until: "the spot to be under the pin") {
            coordinator.placePlacement.pin != nil
                && self.distance(
                    map.convert(spot.coordinate, toPointTo: map),
                    coordinator.focusPoint(in: map)
                ) < Self.pinTolerance
        }
        return token
    }

    @Test("the pin being placed stands in the middle of the visible map, with its spot under it")
    func placementPinStandsInTheMiddle() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        let spot = offCentreSpot(on: map)

        _ = await placePin(at: spot, on: map, coordinator)

        let pin = try #require(coordinator.placePlacement.pin)
        #expect(pin.superview === map)
        #expect(pin.accessibilityIdentifier == "hike-place-placeholder")
        #expect(!map.annotations.contains { $0 is TrailPlaceAnnotation }, "not a pin among the others")
        let focus = coordinator.focusPoint(in: map)
        #expect(focus.y < map.bounds.height * 0.45, "above the sheet, not in the middle of the window")
        // The dot at the foot of the pin is the spot.
        #expect(distance(CGPoint(x: pin.frame.midX, y: pin.frame.maxY - 4), focus) < Self.pinTolerance)
        #expect(map.userTrackingMode == .none, "a map following the hiker would carry the place with them")
        #endif
    }

    @Test("wherever the map comes to rest under the pin is where the place goes")
    func aSettledMapMovesThePlace() async {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        let spot = offCentreSpot(on: map)
        _ = await placePin(at: spot, on: map, coordinator)
        coordinator.mapView(map, regionDidChangeAnimated: false)
        let unmoved = placePins.placement(of: spot).coordinate
        #expect(unmoved.latitude.isApproximatelyEqual(to: spot.latitude, absoluteTolerance: 1e-5))
        #expect(unmoved.longitude.isApproximatelyEqual(to: spot.longitude, absoluteTolerance: 1e-5))

        // The hiker drags the map up and left: the pin now points at ground
        // further down and to the right of where the spot was.
        let dragged = map.convert(
            CGPoint(x: map.bounds.midX + 40, y: map.bounds.midY + 60),
            toCoordinateFrom: map
        )
        map.setCenter(dragged, animated: false)
        coordinator.mapView(map, regionDidChangeAnimated: false)

        let placed = placePins.placement(of: spot)
        #expect(placed.id == spot.id)
        let underPin = map.convert(coordinator.focusPoint(in: map), toCoordinateFrom: map)
        #expect(placed.latitude.isApproximatelyEqual(to: underPin.latitude, absoluteTolerance: 1e-6))
        #expect(placed.longitude.isApproximatelyEqual(to: underPin.longitude, absoluteTolerance: 1e-6))
        #expect(placed.latitude < spot.latitude, "further south than where the form opened")
        #expect(placed.longitude > spot.longitude, "and further east")
        #endif
    }

    /// The middle moving — rotation, or the sheet's rest measured for the
    /// first time — is not the hiker moving the place.
    @Test("a moved middle puts the place back under the pin rather than moving it")
    func aMovedMiddleKeepsThePlace() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        let spot = offCentreSpot(on: map)
        _ = await placePin(at: spot, on: map, coordinator)
        let before = coordinator.focusPoint(in: map)
        // What the map's own settle after the move recorded, rounding and all.
        let held = placePins.placement(of: spot)

        // The sheet's rest is measured once per visit to the middle detent.
        sheetMetrics.detentCommitted(toMiddle: true)
        settle(sheetMetrics, at: map.bounds.height * 0.6)
        let after = coordinator.focusPoint(in: map)
        #expect(distance(before, after) > 10, "precondition: the middle moved")
        coordinator.mapView(map, regionDidChangeAnimated: false)

        // Within a pixel's rounding: the move back is itself a settle MapKit
        // reports, and is read like any other.
        let kept = placePins.placement(of: spot)
        #expect(kept.latitude.isApproximatelyEqual(to: held.latitude, absoluteTolerance: 1e-6), "the place stayed")
        #expect(kept.longitude.isApproximatelyEqual(to: held.longitude, absoluteTolerance: 1e-6))
        #expect(distance(map.convert(held.coordinate, toPointTo: map), after) < Self.pinTolerance)
        let pin = try #require(coordinator.placePlacement.pin)
        #expect(distance(CGPoint(x: pin.frame.midX, y: pin.frame.maxY - 4), after) < Self.pinTolerance)
        #endif
    }

    @Test("the pin goes with the form, and the place it added is an ordinary pin")
    func thePinGoesWithTheForm() async throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let spot = offCentreSpot(on: map)
        let placeholder = HikePlaceDraft().placeholder(at: spot)
        let token = await placePin(at: spot, on: map, coordinator)
        let pin = try #require(coordinator.placePlacement.pin)

        // What *Add* does: the hike holds the place under the placeholder's id.
        placePins.update([placeholder], token: token, placeholder: placeholder)

        await settle(until: "the placement pin to go") { coordinator.placePlacement.pin == nil }
        #expect(pin.superview == nil)
        #expect(coordinator.hikePlaceAnnotations.map(\.place.id) == [spot.id])
        placePins.detach(token: token)
        #endif
    }
}
