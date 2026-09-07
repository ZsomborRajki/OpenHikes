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
}
