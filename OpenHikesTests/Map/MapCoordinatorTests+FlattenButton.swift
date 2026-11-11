//
//  MapCoordinatorTests+FlattenButton.swift
//  OpenHikesTests
//
//  The 2D button over the tracking button: up while the map is tilted, gone
//  while it lies flat, and a tap lays it flat where it is.
//
//  Driven through the two callbacks MapKit drives, a camera that moved and a
//  camera that settled, against a real `MKMapView`. A map with no window runs
//  no animation: the camera a tap asks for lands at once, settle and all. So
//  the frames of a flattening are staged by hand, with the delegate off while
//  the camera is put part of the way down.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
extension MapCoordinatorTests {
    /// Close enough for MapKit to allow a tilt: it allows none from orbit.
    private static let flattenTiltDistance: CLLocationDistance = 3500

    /// Moves `map`'s camera to `pitch` where it already looks, and tells the
    /// coordinator, as a frame of a gesture does.
    private func tilt(
        _ map: MKMapView,
        _ coordinator: MapView.Coordinator,
        to pitch: CLLocationDegrees,
        heading: CLLocationDirection = 0
    ) throws {
        map.camera = MKMapCamera(
            lookingAtCenter: map.centerCoordinate,
            fromDistance: Self.flattenTiltDistance,
            pitch: pitch,
            heading: heading
        )
        try #require(
            map.camera.pitch.isApproximatelyEqual(to: pitch, absoluteTolerance: 1),
            "MapKit must take the tilt, or nothing below tests anything"
        )
        coordinator.mapViewDidChangeVisibleRegion(map)
    }

    /// The button inside the capsule, which is what a thumb lands on.
    private func flattenControl(_ coordinator: MapView.Coordinator) throws -> UIButton {
        let glass = try #require(coordinator.flattenButton as? UIVisualEffectView)
        return try #require(glass.contentView.subviews.compactMap { $0 as? UIButton }.first)
    }

    @Test("a map lying flat offers no 2D button")
    func flatMapOffersNoFlattenButton() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let button = try #require(coordinator.flattenButton)
        #expect(button.isHidden)
        #expect(!button.isUserInteractionEnabled)
    }

    @Test("tilting the map brings the 2D button, and laying it flat takes it away")
    func tiltingShowsTheFlattenButton() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let button = try #require(coordinator.flattenButton)

        try tilt(map, coordinator, to: 30)
        #expect(!button.isHidden)
        #expect(button.isUserInteractionEnabled)
        #expect(button.alpha == 1)

        try tilt(map, coordinator, to: 0)
        #expect(!button.isUserInteractionEnabled, "a control on its way out takes no taps")
        #expect(button.alpha == 0)
    }

    @Test("the 2D button stands on the tracking button")
    func flattenButtonStandsOnTheTrackingButton() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        try tilt(map, coordinator, to: 30)
        map.layoutIfNeeded()

        let flatten = try #require(coordinator.flattenButton).frame
        let tracking = try #require(coordinator.trackingButton).frame
        #expect(flatten.maxX == tracking.maxX)
        #expect(flatten.width == tracking.width)
        #expect(flatten.maxY == tracking.minY - 8)
    }

    @Test("a tap lays the map flat where it is, and the button goes at once")
    func tapLaysTheMapFlat() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        try tilt(map, coordinator, to: 30, heading: 40)
        let before = map.camera

        try flattenControl(coordinator).sendActions(for: .primaryActionTriggered)
        let button = try #require(coordinator.flattenButton)
        #expect(!button.isUserInteractionEnabled)
        #expect(button.alpha == 0)

        let after = map.camera
        #expect(after.pitch.isApproximatelyEqual(to: 0, absoluteTolerance: 0.5))
        #expect(after.heading.isApproximatelyEqual(to: before.heading, absoluteTolerance: 0.5))
        #expect(after.centerCoordinate.latitude.isApproximatelyEqual(
            to: before.centerCoordinate.latitude,
            absoluteTolerance: 1e-4
        ))
        #expect(after.centerCoordinate.longitude.isApproximatelyEqual(
            to: before.centerCoordinate.longitude,
            absoluteTolerance: 1e-4
        ))
        #expect(after.centerCoordinateDistance.isApproximatelyEqual(
            to: before.centerCoordinateDistance,
            relativeTolerance: 0.01
        ))

        coordinator.mapView(map, regionDidChangeAnimated: true)
        #expect(!button.isUserInteractionEnabled, "a map that settled flat offers nothing")
    }

    /// A tap withdraws the button for the whole of the flattening, and the
    /// settle is what ends it: a hiker who catches the map part of the way
    /// down gets the button back for the tilt that is left.
    @Test("the button stays away through a flattening and returns if it is cut short")
    func flatteningKeepsTheButtonAwayUntilItSettles() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        try tilt(map, coordinator, to: 30)
        let button = try #require(coordinator.flattenButton)

        map.delegate = nil
        coordinator.flatten(map)
        map.camera = MKMapCamera(
            lookingAtCenter: map.centerCoordinate,
            fromDistance: Self.flattenTiltDistance,
            pitch: 15,
            heading: 0
        )
        map.delegate = coordinator
        coordinator.mapViewDidChangeVisibleRegion(map)
        #expect(!button.isUserInteractionEnabled, "a frame part of the way down")

        coordinator.mapView(map, regionDidChangeAnimated: true)
        #expect(button.isUserInteractionEnabled)
        #expect(!button.isHidden)
        #expect(button.alpha == 1)
    }

    @Test("the 2D button fades with the sheet, as the tracking button does")
    func flattenButtonFadesWithTheSheet() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let flatten = try #require(coordinator.flattenButton)
        let tracking = try #require(coordinator.trackingButton)
        let middleRest = map.bounds.height * 0.45
        settle(sheetMetrics, at: middleRest)
        coordinator.applySheetTop(on: map)

        // Covered before it is tilted: it arrives at the sheet's opacity, not
        // at full.
        sheetMetrics.report(topY: middleRest - 100, atMiddleDetent: true)
        coordinator.applySheetTop(on: map)
        let covered = tracking.alpha
        try #require(covered > 0 && covered < 1, "precondition: the sheet is part of the way over the column")
        try tilt(map, coordinator, to: 30)
        #expect(flatten.alpha == covered)

        sheetMetrics.report(topY: middleRest, atMiddleDetent: true)
        coordinator.applySheetTop(on: map)
        #expect(flatten.alpha == 1)
        #expect(tracking.alpha == 1)
    }

    @Test("a tap on the 2D button opens nothing under it")
    func tapOnTheFlattenButtonIsClaimed() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        try tilt(map, coordinator, to: 30)
        map.layoutIfNeeded()

        let button = try #require(coordinator.flattenButton)
        let center = CGPoint(x: button.frame.midX, y: button.frame.midY)
        #expect(coordinator.isTapClaimed(at: center, in: map))
    }

    @Test(
        "the button is offered from the tilt terrain rises at",
        arguments: [0.0, 0.5, 1.0, 35.0]
    )
    func flattenIsOfferedWhereTerrainRises(pitch: CLLocationDegrees) {
        #expect(
            MapView.Coordinator.offersFlatten(atPitch: pitch)
                == SystemMapStyle.tilesDrawOnTerrain(atPitch: pitch)
        )
    }
}
#endif
