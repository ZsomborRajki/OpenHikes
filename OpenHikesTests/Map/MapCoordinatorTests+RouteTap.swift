//
//  MapCoordinatorTests+RouteTap.swift
//  OpenHikesTests
//
//  A thumb on a line, and which line it was.
//
//  `MapCoordinatorTests+CommunityRoutes.swift` pins what a shared hike's line
//  is and how it is drawn; `RouteHitTestTests` pins the geometry with no map in
//  the room. These are the part in between: the one recognizer that answers
//  for both kinds of line, what it refuses to answer for, and the order it
//  asks in when a thumb is near both.
//
//  That order is the behaviour worth a test rather than a comment. The hiker's
//  own route is drawn on top, at full strength, in a colour they chose — so
//  where it crosses somebody else's, theirs is the line under the thumb, and a
//  tap that opened a stranger's preview instead would be answering a question
//  nobody asked.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

extension MapCoordinatorTests {
    /// `Fixture.ridgeRoute` is a straight line due north near Cupertino; these
    /// are the numbers needed to point a camera at the middle of it and to lay
    /// a shared hike's line over the same ground.
    private enum Ridge {
        static let latitude: Double = 37.3350
        static let longitude: Double = -122.0300
        /// Wide enough that the whole of the route is on screen at the map
        /// size `makeMap` gives, so a screen point means something.
        static let span: Double = 0.05
        /// Far enough east to be well outside a fingertip of the line at that
        /// span, and still on screen.
        static let wellAwayLongitude: Double = -122.0200
    }

    private static func ridgeRegion() -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: Ridge.latitude, longitude: Ridge.longitude),
            span: MKCoordinateSpan(latitudeDelta: Ridge.span, longitudeDelta: Ridge.span)
        )
    }

    /// The map with the hiker's own route drawn on it, looking at the route.
    ///
    /// The camera is set by hand rather than left to the fit `update` asks
    /// for: that one is animated, and a test that read a screen point before
    /// it landed would be measuring the camera's journey.
    private func mapShowingTheRidge(
        _ coordinator: MapView.Coordinator,
        community: CommunityBrowser = CommunityBrowser(transport: nil, blockList: .scratch())
    ) -> MKMapView {
        let view = mapView(route: Self.route(), community: community)
        let map = makeMap(view, coordinator)
        view.update(map, coordinator)
        map.setRegion(Self.ridgeRegion(), animated: false)
        return map
    }

    private func pointOnTheRidge(in map: MKMapView) -> CGPoint {
        map.convert(
            CLLocationCoordinate2D(latitude: Ridge.latitude, longitude: Ridge.longitude),
            toPointTo: map
        )
    }

    // MARK: - The recognizer

    /// MapKit hit-tests annotations and never overlays, so without the
    /// recognizer every line here would be scenery.
    @Test("building the map installs the tap recognizer once")
    func theTapRecognizerIsInstalledOnce() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let installed = map.gestureRecognizers?.filter { $0 === coordinator.routeTapRecognizer }
        #expect(installed?.count == 1)

        coordinator.installRouteTap(on: map)

        let afterSecondCall = map.gestureRecognizers?.filter { recognizer in
            recognizer === coordinator.routeTapRecognizer
        }
        #expect(afterSecondCall?.count == 1, "a second recognizer would open one screen twice")
        #endif
    }

    /// The recognizer observes and never consumes, and both defaults are
    /// against that.
    ///
    /// `cancelsTouchesInView` is true by default and fires whenever the
    /// recognizer *recognizes* a tap — which is every tap on the map, hit or
    /// miss — so the touch under it is cancelled in whatever view it landed
    /// on. That took photo-pin callouts out of service until
    /// `PhotoUITests.testOpensTheGalleryFromAPhotoPinOnTheMap` said so, and
    /// nothing in this bundle would have noticed: the behaviour is invisible
    /// from the coordinator's side and belongs to a feature this file is not
    /// about. Hence a flag assertion, which is the cheap half of that lesson.
    @Test("the tap recognizer never consumes a touch")
    func theTapRecognizerObservesOnly() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let recognizer = try #require(coordinator.routeTapRecognizer)
        #expect(!recognizer.cancelsTouchesInView, "a callout under the tap has to keep its touch")
        #expect(!recognizer.delaysTouchesEnded, "nothing here needs to arrive before the view's own touch")
        #endif
    }

    // MARK: - The hiker's own line

    /// The gesture this file exists for: a thumb on the route drawn for the
    /// selected hike is a way back into that hike's screen.
    @Test("a tap on the drawn route finds it")
    func aTapOnTheDrawnRouteFindsIt() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = mapShowingTheRidge(coordinator)
        defer { detach(map) }

        #expect(coordinator.routeTapTarget(at: pointOnTheRidge(in: map), in: map) == .drawnRoute)
        #endif
    }

    /// And the other half: a tap on the map is still a tap on the map.
    @Test("a tap away from the drawn route finds nothing")
    func aTapAwayFromTheDrawnRouteFindsNothing() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = mapShowingTheRidge(coordinator)
        defer { detach(map) }
        let wellAway = map.convert(
            CLLocationCoordinate2D(latitude: Ridge.latitude, longitude: Ridge.wellAwayLongitude),
            toPointTo: map
        )

        #expect(coordinator.routeTapTarget(at: wellAway, in: map) == nil)
        #endif
    }

    /// Nothing drawn is nothing to find. The guard is also what keeps a tap on
    /// an empty map from converting a bounding rectangle that describes no
    /// line.
    @Test("a tap finds nothing when no route is drawn")
    func aTapFindsNothingWithoutARoute() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.setRegion(Self.ridgeRegion(), animated: false)

        #expect(coordinator.routeTapTarget(at: pointOnTheRidge(in: map), in: map) == nil)
        #endif
    }

    /// Deselecting is what takes the line off the map, and the points a tap is
    /// measured against have to go with it — otherwise the hike stays tappable
    /// along a line nobody can see.
    @Test("a deselected route stops being tappable")
    func aDeselectedRouteIsNotTappable() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = mapShowingTheRidge(coordinator)
        defer { detach(map) }
        let onTheLine = pointOnTheRidge(in: map)
        #expect(coordinator.routeTapTarget(at: onTheLine, in: map) == .drawnRoute)

        mapView(route: nil).update(map, coordinator)

        #expect(coordinator.routeCoordinates.isEmpty)
        #expect(coordinator.routeTapTarget(at: onTheLine, in: map) == nil)
        #endif
    }

    // MARK: - When both are under the thumb

    /// The order this file's header argues for, on the one tap that can tell
    /// the difference: a shared hike drawn along the same ground as the
    /// hiker's own route, with a thumb on both.
    @Test("the hiker's own line wins over a shared one under the same thumb")
    func theDrawnRouteWinsOverASharedLine() async {
        #if os(iOS)
        let browser = await Self.browserWithRidgeLine()
        let coordinator = MapView.Coordinator()
        let map = mapShowingTheRidge(coordinator, community: browser)
        defer { detach(map) }
        await settle(until: "the shared hike's line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }
        map.setRegion(Self.ridgeRegion(), animated: false)
        let onBoth = pointOnTheRidge(in: map)
        #expect(
            coordinator.communityListing(forTapAt: onBoth, in: map)?.id == "ridge",
            "the shared line has to be under the thumb too, or this proves nothing"
        )

        #expect(coordinator.routeTapTarget(at: onBoth, in: map) == .drawnRoute)
        #endif
    }

    /// And with nothing of the hiker's own drawn there, the same thumb reaches
    /// the shared line — which is what makes the case above a decision rather
    /// than the community hit-test simply being broken.
    @Test("a shared line is still reachable where no route of the hiker's is drawn")
    func aSharedLineIsReachableWithoutADrawnRoute() async {
        #if os(iOS)
        let browser = await Self.browserWithRidgeLine()
        let coordinator = MapView.Coordinator()
        let view = mapView(community: browser)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        await settle(until: "the shared hike's line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }
        map.setRegion(Self.ridgeRegion(), animated: false)

        #expect(
            coordinator.routeTapTarget(at: pointOnTheRidge(in: map), in: map)
                == .communityListing(.stub(id: "ridge"))
        )
        #endif
    }

    // MARK: - What the map's own controls keep

    /// A recognizer on the map view sees a touch whatever the view under it
    /// does with it, so a tap on the "my location" button would otherwise open
    /// a hike *as well as* recentring the map.
    @Test("a tap on a map control is not a tap on a line")
    func aTapOnAControlIsNotATapOnALine() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = mapShowingTheRidge(coordinator)
        defer { detach(map) }

        // Put the tracking button squarely on the line, which is the case a
        // hit-test has to resolve and a distance cannot.
        let button = try #require(coordinator.trackingButton)
        let onTheLine = pointOnTheRidge(in: map)
        #expect(
            coordinator.routeTapTarget(at: onTheLine, in: map) == .drawnRoute,
            "the line is where the button is about to be"
        )
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = CGRect(
            x: onTheLine.x - Self.buttonRadius,
            y: onTheLine.y - Self.buttonRadius,
            width: Self.buttonRadius * 2,
            height: Self.buttonRadius * 2
        )

        #expect(coordinator.routeTapTarget(at: onTheLine, in: map) == nil)
        #endif
    }

    /// Half a minimum tap target, which is the size the button is given here
    /// so that it covers the point being tapped.
    private static let buttonRadius: CGFloat = 22

    /// A browser holding one published hike whose line runs along the ridge,
    /// without anything having to happen on a network.
    private static func browserWithRidgeLine() async -> CommunityBrowser {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([
            .stub(id: "ridge", latitude: Ridge.latitude, longitude: Ridge.longitude),
        ])
        transport.outlinesResult = .success([
            "ridge": Fixture.ridgeRoute,
        ])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(ridgeRegion())
        browser.startBrowsing()
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
        return browser
    }
}
