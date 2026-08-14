//
//  MapCoordinatorTests+Commands.swift
//  OpenHikesTests
//
//  The three one-shot commands the rest of the app sends the map — Zoom in the
//  detail view, a search result in the sheet, Follow in the recording view.
//  None of them travel through SwiftUI: each is a counter on `MapController`
//  that `MapView.Coordinator` observes with `withObservationTracking` and
//  applies straight to `MKMapView`.
//
//  What that buys in render cost it pays for in a subtlety worth pinning:
//  `withObservationTracking` fires exactly once, its `onChange` runs during the
//  `willSet` of the very mutation that triggered it, and re-arming therefore
//  has to happen from a `Task { @MainActor in … }` afterwards — Observation
//  documents reading tracked state inside `onChange` as unsupported, so
//  re-arming "before the hop" is not on the table.
//
//  Two bumps in one run-loop turn consequently produce one notification rather
//  than two. The tests below are about what survives that: the command still
//  runs, it runs against the newest payload, and the observer is still armed
//  afterwards. A lost *notification* is only a bug if it loses the *effect*,
//  and these are the assertions that tell those two apart.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// The coalescing case, on the one command whose result is a plain
    /// synchronous property rather than an animated viewport: two bumps in a
    /// single turn deliver one notification, and the map still ends up
    /// following.
    ///
    /// The second half is the one that matters. Re-arming happens inside the
    /// same `Task` body that applies the command, with no `await` between
    /// them, so nothing can bump the counter in the gap — and a third command,
    /// a turn later, proves the observer outlived the pair rather than being
    /// consumed by it.
    @Test("two commands in one turn still reach the map, and don't end the observation")
    func coalescedCommandsKeepTheirEffect() async {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        map.setUserTrackingMode(.none, animated: false)

        mapController.followUser()
        mapController.followUser()
        await settle()
        #expect(map.userTrackingMode == .follow, "the coalesced notification still has to move the map")

        map.setUserTrackingMode(.none, animated: false)
        mapController.followUser()
        await settle()
        #expect(
            map.userTrackingMode == .follow,
            "re-arming happens with no suspension after the command, so the next one is still heard"
        )
    }

    /// The payload half. `show(_:)` writes `region` before bumping its counter,
    /// and the coordinator reads `region` when the task runs rather than when
    /// the notification fired — so two searches resolving in the same turn land
    /// on the second one's region, not the first's.
    ///
    /// That is also the behaviour worth having: the first region would be
    /// overwritten a frame later anyway, and animating through it costs a
    /// viewport change nobody asked for.
    @Test("two regions in one turn converge on the last")
    func coalescedRegionsUseTheNewestPayload() async {
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        mapController.show(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            latitudinalMeters: 4000,
            longitudinalMeters: 4000
        ))
        mapController.show(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.71, longitude: -74.00),
            latitudinalMeters: 4000,
            longitudinalMeters: 4000
        ))
        await settle()

        #expect(abs(map.region.center.latitude - 40.71) < 0.05, "the newest region is the one the user asked for")
        #expect(abs(map.region.center.longitude + 74.00) < 0.05)
    }

    /// And the commands stay independent under coalescing too: a run of
    /// `followUser()` must not also re-fit the route, which would throw away a
    /// viewport the user had panned to.
    @Test("a run of one command leaves the others alone")
    func coalescingDoesNotCrossCommands() async throws {
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        // Drawing the route also fits it into view, *animated*, and MapKit
        // runs that out on CoreAnimation's clock rather than the scheduler's.
        // Panning away while the fit is still in flight leaves the map
        // wherever the animation ends — on the route — which reads exactly
        // like the regression below and failed this test on CI for it.
        let routeCentre = try #require(coordinator.routeOverlay).coordinate
        await settleViewport(of: map, at: routeCentre)

        let elsewhere = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.71, longitude: -74.00),
            latitudinalMeters: 4000,
            longitudinalMeters: 4000
        )
        map.setRegion(elsewhere, animated: false)
        map.setUserTrackingMode(.none, animated: false)

        mapController.followUser()
        mapController.followUser()
        await settle()

        #expect(map.userTrackingMode == .follow)
        #expect(
            abs(map.region.center.latitude - 40.71) < 0.5,
            "following the user must not have re-fitted the route"
        )
    }
}
