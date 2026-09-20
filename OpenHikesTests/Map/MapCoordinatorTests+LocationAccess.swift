//
//  MapCoordinatorTests+LocationAccess.swift
//  OpenHikesTests
//
//  Which of the two buttons the tracking capsule is showing.
//
//  The bug underneath: `MKUserTrackingButton` sends its tap to the map view,
//  and a map view asked to follow a user it has no authorization to locate
//  spins a small indicator and gives up. Nothing about that is overridable —
//  the glyph is private and the tap never reaches this app — so the only way
//  to stop it is for that button not to be on screen. The capsule therefore
//  holds two, and this is the file that pins which one is visible when.
//
//  The suite's own `locationManager` wraps a real `CLLocationManager`, whose
//  status is whatever the test host happens to have been granted. So these
//  build their own around a stub, through the `locationManager:` parameter
//  `MapCoordinatorTests.mapView(...)` carries for exactly this.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
extension MapCoordinatorTests {
    /// A feed whose authorization the test sets, and which does nothing else.
    private final class StubAccessSource: ForegroundLocationSource {
        var foregroundAuthorizationStatus: CLAuthorizationStatus
        weak var delegateObject: AnyObject?
        var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest
        var distanceFilter: CLLocationDistance = kCLDistanceFilterNone

        init(_ status: CLAuthorizationStatus) {
            foregroundAuthorizationStatus = status
        }

        var foregroundDelegate: CLLocationManagerDelegate? {
            get { delegateObject as? CLLocationManagerDelegate }
            set { delegateObject = newValue }
        }

        func requestWhenInUseAuthorization() { /* nothing to answer here */ }
        func startUpdatingLocation() { /* no fixes in these tests */ }
        func stopUpdatingLocation() { /* nor any to end */ }
    }

    private func makeMapForAccess(
        _ status: CLAuthorizationStatus
    ) -> (MKMapView, MapView.Coordinator, LocationManager) {
        let manager = LocationManager(manager: StubAccessSource(status))
        let coordinator = MapView.Coordinator()
        let view = mapView(locationManager: manager)
        return (makeMap(view, coordinator), coordinator, manager)
    }

    /// The ordinary case, and the one a regression here would break silently:
    /// a hiker who granted access must still get MapKit's button.
    @Test("an authorized map shows MapKit's own button")
    func authorizedShowsTrackingButton() {
        let (map, coordinator, _) = makeMapForAccess(.authorizedWhenInUse)
        defer { detach(map) }

        #expect(coordinator.trackingGlyph?.isHidden == false)
        #expect(coordinator.refusedTrackingButton?.isHidden == true)
    }

    /// The reported one. The button that spins is gone before it can be
    /// tapped — this is drawn on the map's first pass, because a hiker who
    /// refused months ago has no authorization change coming to prompt a
    /// second.
    @Test("a refused map shows the stand-in instead")
    func deniedShowsRefusedButton() {
        let (map, coordinator, _) = makeMapForAccess(.denied)
        defer { detach(map) }

        #expect(coordinator.trackingGlyph?.isHidden == true)
        #expect(coordinator.refusedTrackingButton?.isHidden == false)
    }

    /// An unanswered prompt is not a refusal: the hiker has not said no, and
    /// MapKit's button is what asks.
    @Test("an unasked map shows MapKit's own button")
    func notDeterminedShowsTrackingButton() {
        let (map, coordinator, _) = makeMapForAccess(.notDetermined)
        defer { detach(map) }

        #expect(coordinator.trackingGlyph?.isHidden == false)
        #expect(coordinator.refusedTrackingButton?.isHidden == true)
    }

    /// The swap runs the other way too, which is what a trip to Settings and
    /// back looks like from here — and why this is observed rather than read
    /// once when the map is built.
    @Test("granting access later puts MapKit's button back")
    func grantingAccessRestoresTrackingButton() async {
        let source = StubAccessSource(.denied)
        let manager = LocationManager(manager: source)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(locationManager: manager), coordinator)
        defer { detach(map) }
        #expect(coordinator.refusedTrackingButton?.isHidden == false, "precondition: refused")

        source.foregroundAuthorizationStatus = .authorizedWhenInUse
        // What `sceneDidBecomeActive` does on the way back in: re-read the
        // grant, which is the assignment the observation below is waiting on.
        manager.resume()
        await settleDelegateHop(until: "the capsule to swap back") {
            coordinator.refusedTrackingButton?.isHidden == true
        }

        #expect(coordinator.trackingGlyph?.isHidden == false)
        #expect(coordinator.refusedTrackingButton?.isHidden == true)
    }

    /// …and a grant withdrawn in Settings takes it away again.
    @Test("withdrawing access swaps the stand-in back in")
    func withdrawingAccessShowsRefusedButton() async {
        let source = StubAccessSource(.authorizedWhenInUse)
        let manager = LocationManager(manager: source)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(locationManager: manager), coordinator)
        defer { detach(map) }
        #expect(coordinator.trackingGlyph?.isHidden == false, "precondition: authorized")

        source.foregroundAuthorizationStatus = .denied
        manager.resume()
        await settleDelegateHop(until: "the capsule to swap") {
            coordinator.refusedTrackingButton?.isHidden == false
        }

        #expect(coordinator.trackingGlyph?.isHidden == true)
    }

    // MARK: What the stand-in does when it is tapped

    /// The other half of the fix. A button that no longer spins but still does
    /// nothing is the same complaint one step along.
    @Test("tapping the stand-in raises the alert")
    func refusedButtonRaisesThePrompt() throws {
        let (map, coordinator, _) = makeMapForAccess(.denied)
        defer { detach(map) }
        let refused = try #require(coordinator.refusedTrackingButton)
        #expect(!locationAccessPrompt.isShowing, "precondition: nothing showing")

        refused.sendActions(for: .touchUpInside)

        #expect(locationAccessPrompt.isShowing)
    }

    /// A glyph is not a label. `performAccessibilityAudit` measures both, and
    /// this button is the one that replaces a control MapKit named for us.
    @Test("the stand-in carries a spoken name of its own")
    func refusedButtonIsNamed() throws {
        let (map, coordinator, _) = makeMapForAccess(.denied)
        defer { detach(map) }

        let refused = try #require(coordinator.refusedTrackingButton)
        #expect(refused.accessibilityLabel?.isEmpty == false)
        #expect(refused.accessibilityHint?.isEmpty == false)
    }
}
#endif
