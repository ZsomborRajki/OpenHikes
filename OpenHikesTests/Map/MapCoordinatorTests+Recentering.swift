//
//  MapCoordinatorTests+Recentering.swift
//  OpenHikesTests
//
//  Who owns the viewport, and for how long.
//
//  Two things ask to decide what the map is looking at: the user's first
//  location fix, and a selected route. The rule is that the fix gets one
//  chance and a route outranks it — and the part worth pinning is that the
//  chance is spent by the fix *arriving*, not by the map moving. A first fix
//  that a route quietly swallowed used to stay owed, so closing the trail
//  handed the next fix a recentre nobody asked for, seconds later and
//  seemingly out of nowhere.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

extension MapCoordinatorTests {
    /// The map centres on the user's first fix — once. A second fix a second
    /// later must not drag the map back while they're panning it.
    @Test("the first fix centres the map, and only the first")
    func firstFixCentresOnce() async {
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
        // `hasCentered` and then calls `setRegion(_:animated: true)`, so the
        // map can still be moving when the flag is already true. Capturing
        // `centred` mid-animation would make the comparison below fail for a
        // reason that has nothing to do with the second fix.
        await settleDelegateHop(until: "the first fix to centre the map") {
            coordinator.hasHandledFirstFix && abs(map.region.center.latitude - 47.6300) < Self.centreTolerance
        }
        #expect(coordinator.hasHandledFirstFix)
        let centred = map.region.center.latitude

        // Past the publish throttle, so the map really is offered this one.
        clock.advance(by: 1.1)
        locationManager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6400, longitude: 12.8600)]
        )
        await settleDelegateHop(until: "the second fix to be published") {
            locationManager.coordinate?.latitude == 47.6400
        }

        #expect(locationManager.coordinate?.latitude == 47.6400, "precondition: the second fix was published")
        #expect(map.region.center.latitude == centred, "a later fix must not drag the map back")
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
            abs(map.region.center.latitude - 47.6300) > Self.centreTolerance,
            "the route decides what's on screen"
        )
    }

    /// The fix that arrived while a route was selected is spent, not saved.
    /// Otherwise closing the trail — which leaves the map exactly where the
    /// user was looking — arms the next fix to yank it away a second later.
    @Test("deselecting a route doesn't arm the next fix to recentre")
    func deselectingARouteDoesNotArmARecentre() async {
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

        // Past the publish throttle, so the map really is offered this one.
        clock.advance(by: 1.1)
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
            abs(map.region.center.latitude - 47.6400) > Self.centreTolerance,
            "a fix after deselection must not pull the map onto the user"
        )
    }
}
