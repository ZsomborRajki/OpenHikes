import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    @Test("side panel leaves controls in the unobscured safe area", arguments: [false, true])
    func sidePanelControlFrames(rightToLeft: Bool) throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView(sidePanelInset: MapSidePanelLayout.mapInset)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        map.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        map.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
        view.update(map, coordinator)
        map.layoutIfNeeded()
        let constraint = try #require(coordinator.controlsLeadingConstraint)
        let guide = try #require(constraint.firstItem as? UILayoutGuide)
        let safe = map.safeAreaLayoutGuide.layoutFrame
        let inset = MapSidePanelLayout.mapInset
        #expect(abs(guide.layoutFrame.minX - (safe.minX + (rightToLeft ? 0 : inset))) < 1)
        #expect(abs(guide.layoutFrame.maxX - (safe.maxX - (rightToLeft ? inset : 0))) < 1)
        let credit = try #require(coordinator.attributionView)
        let tracking = try #require(coordinator.trackingButton)
        for control in [credit, tracking] {
            #expect(control.frame.minX >= guide.layoutFrame.minX)
            #expect(control.frame.maxX <= guide.layoutFrame.maxX)
        }

        mapView().update(map, coordinator)
        map.setNeedsLayout()
        map.layoutIfNeeded()
        #expect(guide.layoutFrame == safe, "portrait returns both edges")
        #endif
    }

    @Test("route fitting clears the landscape panel", arguments: [false, true])
    func sidePanelRouteFit(rightToLeft: Bool) {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView(sidePanelInset: MapSidePanelLayout.mapInset)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        map.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        map.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
        view.update(map, coordinator)
        map.layoutIfNeeded()
        let coordinates = [
            CLLocationCoordinate2D(latitude: 47.7, longitude: 12.8),
            CLLocationCoordinate2D(latitude: 47.701, longitude: 12.9),
        ]
        coordinator.routeOverlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
        coordinator.fitToCurrentRoute(map, animated: false)
        let safe = map.safeAreaLayoutGuide.layoutFrame
        let minimumX = safe.minX + (rightToLeft ? 0 : MapSidePanelLayout.mapInset)
        let maximumX = safe.maxX - (rightToLeft ? MapSidePanelLayout.mapInset : 0)
        for coordinate in coordinates {
            let point = map.convert(coordinate, toPointTo: map)
            #expect(point.x >= minimumX, "the fitted route must clear the panel")
            #expect(point.x <= maximumX, "the fitted route must remain on screen")
            #expect(point.y >= 0 && point.y <= map.bounds.height)
        }
        #endif
    }

    /// Landscape has no sheet, so the leading-edge stack belongs at the bottom
    /// of the map rather than a sheet's height above it.
    ///
    /// The bug this pins is the fallback in `sheetTop(in:)` being applied to a
    /// state it was not written for. It exists for the first frames of a
    /// *launch*, before the sheet has reported a top edge — and `withdraw()`
    /// leaves exactly the same reading behind on the way into landscape, where
    /// there is no sheet to leave room for. The credit line and the camera pill
    /// above it floated 92 points up with nothing underneath them.
    ///
    /// The map here is not in a window, so `safeAreaInsets.bottom` is zero and
    /// the expected constant is the map's own height less the spacing. Reading
    /// it off the map rather than writing 0 is what keeps this true on a device
    /// with a home indicator.
    @Test("a side panel puts the leading controls against the bottom of the map")
    func sidePanelDropsTheControlsToTheBottom() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let credit = try #require(coordinator.attributionBottomConstraint)
        let tracking = try #require(coordinator.trackingBottomConstraint)
        let spacing: CGFloat = 16

        coordinator.applySheetTop(on: map)
        #expect(
            credit.constant < map.bounds.height - spacing,
            "precondition: portrait keeps room for the sheet it cannot see yet"
        )

        mapView(sidePanelInset: MapSidePanelLayout.mapInset).update(map, coordinator)
        // What rotating actually does to the metrics — see `SheetMetrics.withdraw()`.
        sheetMetrics.withdraw()
        coordinator.applySheetTop(on: map)

        let bottom = map.bounds.height - map.safeAreaInsets.bottom - spacing
        #expect(credit.constant == bottom)
        #expect(tracking.constant == bottom, "the row stays one row")
        let button = try #require(coordinator.trackingButton)
        #expect(button.alpha == 1, "there is nothing over them to fade behind")

        mapView().update(map, coordinator)
        coordinator.applySheetTop(on: map)
        #expect(
            credit.constant < bottom,
            "and portrait leaves room for the sheet again"
        )
        #endif
    }

    /// MapKit's own compass and scale are laid out against the map's margins,
    /// and the map fills the window — so without these they sit against the
    /// screen's edge, and in landscape behind the panel.
    ///
    /// The scale is the one that matters: `showsScale` is adaptive, so it is
    /// drawn only while the hiker is pinching, and a reference distance only
    /// ever drawn underneath a panel is one the map does not have.
    @Test("MapKit's own controls are given margins that clear the panel")
    func builtInControlsClearThePanel() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let inset = MapView.controlInset

        view.update(map, coordinator)
        #expect(map.directionalLayoutMargins.top == inset)
        #expect(map.directionalLayoutMargins.leading == inset)

        mapView(sidePanelInset: MapSidePanelLayout.mapInset).update(map, coordinator)
        #expect(map.directionalLayoutMargins.leading == MapSidePanelLayout.mapInset + inset)
        #expect(map.directionalLayoutMargins.top == inset, "a panel takes a side, not the top")

        mapView().update(map, coordinator)
        #expect(map.directionalLayoutMargins.leading == inset, "and gives the edge back")
        #endif
    }
}
