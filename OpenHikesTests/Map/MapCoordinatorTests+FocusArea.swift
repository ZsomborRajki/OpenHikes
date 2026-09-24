//
//  MapCoordinatorTests+FocusArea.swift
//  OpenHikesTests
//
//  Which part of the map a camera move is allowed to aim at.
//
//  The map fills the window and the sheet covers the bottom of it, so "put
//  this route on screen" and "put this route where the hiker can see it" are
//  two different instructions — and the app used to give the first one. Every
//  assertion here is the second: a projection of what was framed back into the
//  view, compared against where the sheet starts.
//
//  Test maps are not in a window, so `SheetMetrics` has never watched a sheet
//  come to rest unless a test settles one itself. That is not a gap in the
//  fixture but the launch case: the first route a restored selection draws is
//  fitted before any sheet has rested anywhere, which is why the unmeasured
//  fallback has a test of its own rather than being treated as a corner.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

extension MapCoordinatorTests {
    /// A trail that fills a good part of the map, so "did it land above the
    /// sheet" is a question about framing rather than about a dot.
    private enum Trail {
        static let points = 8
        static let latitude = 47.60
        static let longitude = 12.80
        static let latitudeStep = 0.01
        static let longitudeStep = 0.008
        static let elevation = 600.0
        static let elevationStep = 25.0
    }

    private static func alpineRoute() -> DisplayedRoute {
        route(coordinates: (0..<Trail.points).map { step in
            RouteCoordinate(
                latitude: Trail.latitude + Double(step) * Trail.latitudeStep,
                longitude: Trail.longitude + Double(step) * Trail.longitudeStep,
                elevation: Trail.elevation + Double(step) * Trail.elevationStep
            )
        })
    }

    /// Where the route ended up, in the view's own points.
    private func projected(
        _ rect: MKMapRect,
        on map: MKMapView
    ) -> (top: CGFloat, bottom: CGFloat) {
        let north = map.convert(MKMapPoint(x: rect.minX, y: rect.minY).coordinate, toPointTo: map)
        let south = map.convert(MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate, toPointTo: map)
        return (min(north.y, south.y), max(north.y, south.y))
    }

    /// The whole point: a fitted route lands in the map the sheet is *not*
    /// over.
    ///
    /// Before this, the route was framed into the window and the sheet then
    /// covered the lower half of it — so a there-and-back walk had its far end
    /// behind the sheet at the exact moment the hiker pressed *Zoom*.
    @Test("a fitted route lands above the sheet")
    func aFittedRouteClearsTheSheet() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.alpineRoute())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let restY = map.bounds.height * 0.45
        settle(sheetMetrics, at: restY)
        #expect(sheetMetrics.middleRestY == restY, "precondition: the sheet was measured")

        coordinator.fitToCurrentRoute(map, animated: false)

        let polyline = try #require(coordinator.routeOverlay)
        let route = projected(polyline.boundingMapRect, on: map)
        #expect(route.bottom <= restY, "the route's far end must not be behind the sheet")
        #expect(route.top >= 0, "and its near end must not be off the top")
        #endif
    }

    /// And before any sheet has been watched, which is what a launch is.
    ///
    /// The fallback is a fraction rather than a measurement, so what is
    /// asserted is the property the fraction is chosen for: erring towards a
    /// route that is fully visible. It is checked against the same constant
    /// the code reads rather than against `0.57`, because pinning the number
    /// twice is how the two drift apart.
    @Test("a fitted route clears the sheet before one has been measured")
    func anUnmeasuredSheetStillGetsItsRoom() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.alpineRoute())
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        #expect(sheetMetrics.middleRestY == nil, "precondition: nothing has watched a sheet")

        coordinator.fitToCurrentRoute(map, animated: false)

        let assumedTop = map.bounds.height
            * (1 - MapView.Coordinator.assumedMiddleDetentShare)
        let polyline = try #require(coordinator.routeOverlay)
        #expect(projected(polyline.boundingMapRect, on: map).bottom <= assumedTop)
        #endif
    }

    /// A region is shown through the same measurement, which is the half that
    /// had no padding at all: `setRegion` centres on the *window*, so a
    /// searched place and a photograph's pin both landed under the sheet.
    @Test("a shown region lands above the sheet")
    func aShownRegionClearsTheSheet() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView()
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let restY = map.bounds.height * 0.45
        settle(sheetMetrics, at: restY)
        let centre = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)

        coordinator.show(
            MKCoordinateRegion(center: centre, latitudinalMeters: 4000, longitudinalMeters: 4000),
            on: map,
            animated: false
        )

        let point = map.convert(centre, toPointTo: map)
        #expect(point.y <= restY, "the place asked for must not be behind the sheet")
        #expect(point.y >= 0)
        #endif
    }

    /// Landscape takes a side rather than the bottom, and takes it in
    /// *physical* terms — which is the conversion this is here to hold.
    @Test("the focus area follows the panel's edge, not the leading one", arguments: [false, true])
    func obstructionFollowsThePhysicalEdge(rightToLeft: Bool) {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView(sidePanelInset: MapSidePanelLayout.mapInset)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        map.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
        view.update(map, coordinator)

        let insets = coordinator.obstructionInsets(in: map)

        #expect(insets.bottom == 0, "a panel is not a sheet: the bottom of the map is clear")
        if rightToLeft {
            #expect(insets.right >= MapSidePanelLayout.mapInset)
            #expect(insets.left == 0)
        } else {
            #expect(insets.left >= MapSidePanelLayout.mapInset)
            #expect(insets.right == 0)
        }
        #endif
    }

    /// The padding is the sum of two things that do not know about each other
    /// — a sheet's height and a route's breathing room — so on a short window
    /// it can exceed the view, which `setVisibleMapRect` does not define.
    @Test("padding is scaled down rather than allowed to exceed the view")
    func paddingIsClampedToTheView() {
        let size = CGSize(width: 390, height: 300)
        let insets = MapEdgeInsets(top: 80, left: 60, bottom: 260, right: 60)

        let clamped = MapView.Coordinator.clamped(insets, toFit: size)

        let minimum = MapView.Coordinator.minimumViewport
        #expect(clamped.top + clamped.bottom <= size.height - minimum + 0.001)
        #expect(clamped.left + clamped.right == 120, "the axis that fits is left alone")
        #expect(
            clamped.bottom > clamped.top,
            "and the shape of the padding survives the scaling"
        )
    }

    /// Padding that already fits is handed back untouched, so the ordinary
    /// case pays nothing for the guard above.
    @Test("padding that fits is not touched")
    func paddingThatFitsIsUnchanged() {
        let insets = MapEdgeInsets(top: 80, left: 60, bottom: 400, right: 60)
        #expect(
            MapView.Coordinator.clamped(insets, toFit: CGSize(width: 390, height: 844)) == insets
        )
    }
}
