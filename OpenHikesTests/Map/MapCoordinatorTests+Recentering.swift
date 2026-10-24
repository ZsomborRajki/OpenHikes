//
//  MapCoordinatorTests+Recentering.swift
//  OpenHikesTests
//
//  Who owns the viewport, and for how long.
//
//  Three things ask to decide what the map is looking at: the user's first
//  location fix, a selected route, and a UI-test launch that names where the
//  map starts (`--ui-test-map-start`). The rule is that the fix gets one
//  chance and a route outranks it — and the part worth pinning is that the
//  chance is spent by the fix *arriving*, not by the map moving. A first fix
//  that a route quietly swallowed used to stay owed, so closing the trail
//  handed the next fix a recentre nobody asked for, seconds later and
//  seemingly out of nowhere. A launch's start stands in for the fix: it takes
//  that one chance ahead of any fix, on the same terms.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import SwiftUI
import Testing

extension MapCoordinatorTests {
    /// The map centres on the user's first fix — once. A second fix a second
    /// later must not drag the map back while they're panning it.
    @Test("the first fix centres the map, and only the first")
    func firstFixCentersOnce() async {
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        // Waits for the region, not just for the flag: `centerOnUser` sets
        // `hasHandledFirstFix` and then calls `setRegion(_:animated: true)`,
        // so the map can still be moving when the flag is already true.
        // Capturing `centered` mid-animation would make the comparison below
        // fail for a reason that has nothing to do with the second fix.
        await settleDelegateHop(until: "the first fix to centre the map") {
            coordinator.hasHandledFirstFix
                && map.region.center.latitude.isApproximatelyEqual(to: 47.6300, absoluteTolerance: Self.centerTolerance)
        }
        #expect(coordinator.hasHandledFirstFix)
        let centered = map.region.center.latitude

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6400, longitude: 12.8600)]
        )
        await settleDelegateHop(until: "the second fix to be published") {
            locationManager.coordinate?.latitude == 47.6400
        }

        #expect(locationManager.coordinate?.latitude == 47.6400, "precondition: the second fix was published")
        #expect(map.region.center.latitude == centered, "a later fix must not drag the map back")
    }

    /// A launch that names where the map starts is framed there before any
    /// fix, and the fix that follows finds its one chance spent — which is
    /// what makes a community scenario look at the same place whatever the
    /// location permission on the simulator says (#1041).
    @Test("a launch's map start frames the map, and spends the first fix")
    func launchMapStartStandsInForTheFirstFix() async {
        let coordinator = MapView.Coordinator()
        coordinator.launchMapStart = CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        #expect(coordinator.hasHandledFirstFix, "the start is handled as the first fix, before any fix arrives")
        await settleDelegateHop(until: "the start to frame the map") {
            map.region.center.latitude.isApproximatelyEqual(to: 47.6300, absoluteTolerance: Self.centerTolerance)
        }
        let started = map.region.center.latitude

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6400, longitude: 12.8600)]
        )
        await settleDelegateHop(until: "the fix to be published") {
            locationManager.coordinate?.latitude == 47.6400
        }
        await settle()

        #expect(locationManager.coordinate?.latitude == 47.6400, "precondition: the fix was published")
        #expect(map.region.center.latitude == started, "a fix after the start must not move the map")
    }

    /// A selected route owns the viewport. Centring on the user as well would
    /// yank the map off the trail the moment a fix arrives.
    @Test("a fix doesn't recentre while a route is selected")
    func routeOwnsTheViewport() async {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        // The wait is the first half of the assertion: the coordinator has to
        // *see* the fix — and record it — even though it must not act on it.
        await settle(until: "the first fix to reach the coordinator") {
            coordinator.hasHandledFirstFix
        }

        // Stated as a distance from the fix rather than as "the region didn't
        // change": fitting the route is animated, so the region is still
        // moving here — towards the trail near 37.33, and never towards
        // Austria.
        #expect(
            abs(map.region.center.latitude - 47.6300) > Self.centerTolerance,
            "the route decides what's on screen"
        )
    }

    /// The fix that arrived while a route was selected is spent, not saved.
    /// Otherwise closing the trail — which leaves the map exactly where the
    /// user was looking — arms the next fix to yank it away a second later.
    @Test("deselecting a route doesn't arm the next fix to recentre")
    func deselectingARouteDoesNotArmARecenter() async {
        let coordinator = MapView.Coordinator()
        let selected = mapView(route: Self.route())
        let map = makeMap(selected, coordinator)
        defer { detach(map) }
        selected.update(map, coordinator)

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        await settle(until: "the first fix to reach the coordinator") {
            coordinator.hasHandledFirstFix
        }

        // Deselecting drops the line but leaves the viewport where the user
        // was looking — which is the framing the assertion below defends.
        mapView().update(map, coordinator)
        #expect(coordinator.routeID == nil, "precondition: the route was deselected")

        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6400, longitude: 12.8600)]
        )
        await settleDelegateHop(until: "the second fix to be published") {
            locationManager.coordinate?.latitude == 47.6400
        }
        // Publishing is only half of it: the coordinator sees the fix one
        // main-actor hop later, and it is what it does there that is on trial.
        await settle()

        #expect(locationManager.coordinate?.latitude == 47.6400, "precondition: the second fix was published")
        #expect(
            abs(map.region.center.latitude - 47.6400) > Self.centerTolerance,
            "a fix after deselection must not pull the map onto the user"
        )
    }
}
