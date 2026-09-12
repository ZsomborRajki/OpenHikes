//
//  MapCoordinatorTests+CommunityRoutes.swift
//  OpenHikesTests
//
//  What the map does with the shapes of the shared hikes in the list.
//
//  `MapCoordinatorTests+CommunityPins.swift` pins the markers: that the
//  results reach MapKit, and that a tap on one opens the preview. These pin
//  the other half of the same answer — the lines — and the three things that
//  are only true of a line.
//
//  A line is *drawn* rather than placed, so what a renderer does with it is
//  the behaviour: faded and beneath the hiker's own route when it is somebody
//  else's suggestion, full strength when it is the hike they are looking at.
//  A line is not an accessibility element and cannot be hit-tested by MapKit,
//  so the way in has to be found by hand. And a line is rebuilt wholesale, so
//  the guard against churning every overlay on an identical answer is load
//  bearing rather than a nicety.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

extension MapCoordinatorTests {
    private enum Area {
        static let latitude: Double = 47.63
        static let longitude: Double = 12.86
        static let spanMeters: Double = 20_000
        static let metersPerDegree: Double = 111_320
        /// How far south of the searched centre a drawn line starts, and how
        /// far each of its points steps north — so the whole of it crosses the
        /// middle of the region the browser settles on.
        static let lineOrigin = 0.02
        static let lineStep = 0.005
        static let linePoints = 9
    }

    private static func communityRegion() -> MKCoordinateRegion {
        let degrees = Area.spanMeters / Area.metersPerDegree
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: Area.latitude, longitude: Area.longitude),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    /// A line across the middle of the searched area, so it is on screen at
    /// the region the browser settles on.
    private static func line(offsetting longitude: Double = 0) -> [RouteCoordinate] {
        (0..<Area.linePoints).map { index in
            RouteCoordinate(
                latitude: Area.latitude - Area.lineOrigin + Double(index) * Area.lineStep,
                longitude: Area.longitude + longitude
            )
        }
    }

    /// A browser holding published hikes and the shapes behind them, without
    /// anything having to happen on a network.
    private func browserWithLines(
        _ listings: [CommunityListing],
        outlines: [String: [RouteCoordinate]]
    ) async -> CommunityBrowser {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success(listings)
        transport.outlinesResult = .success(outlines)
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.communityRegion())
        browser.startBrowsing()
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
        return browser
    }

    // MARK: - Drawing them

    /// The loop this file is about: an answer reaches MapKit as trails rather
    /// than as points, with no SwiftUI body in between.
    @Test("published hikes become lines on the map")
    func listingsBecomeOverlays() async {
        let browser = await browserWithLines(
            [.stub(id: "ridge"), .stub(id: "summit", submissionID: "submission-2")],
            outlines: ["ridge": Self.line(), "summit": Self.line(offsetting: 0.02)]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }

        await settle(until: "the shared hikes' lines to reach the map") {
            coordinator.communityRoutes.count == 2
        }
        #expect(coordinator.communityRoutes.map(\.line.id) == ["ridge", "summit"])
        let drawn = coordinator.communityRoutes.map(\.polyline)
        #expect(drawn.allSatisfy { polyline in map.overlays.contains { $0 === polyline } })
    }

    /// Somebody else's trail at half strength, so it is legible without ever
    /// competing with the route the hiker chose a colour for.
    @Test("a shared hike's line is drawn faded")
    func aSharedLineIsFaded() async throws {
        let browser = await browserWithLines(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.line()]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }

        let polyline = try #require(coordinator.communityRoutes.first?.polyline)
        let renderer = try #require(
            coordinator.mapView(map, rendererFor: polyline) as? MKPolylineRenderer
        )
        #if os(iOS)
        let alpha = try #require(renderer.strokeColor?.cgColor.alpha)
        #expect(alpha < 1, "a stranger's trail must not read as the hiker's own")
        #endif
    }

    /// The preview no longer draws the route anywhere else, so this is where
    /// the hiker sees what they are deciding about.
    @Test("the open preview's line is drawn at full strength")
    func thePreviewedLineIsEmphasised() async throws {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browserWithLines([listing], outlines: ["ridge": Self.line()])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }

        browser.previewOpened(listing)
        browser.previewLoaded(Self.line(), of: listing)
        await settle(until: "the preview's own route to replace the outline") {
            coordinator.communityRoutes.first?.line.isPreviewed == true
        }

        #expect(coordinator.communityRoutes.count == 1, "one trail, not two versions of it")
        let polyline = try #require(coordinator.communityRoutes.first?.polyline)
        let renderer = try #require(
            coordinator.mapView(map, rendererFor: polyline) as? MKPolylineRenderer
        )
        #if os(iOS)
        #expect(renderer.strokeColor?.cgColor.alpha == 1)
        #endif
    }

    /// The map belongs to the hiker's own hike. A shared trail is added below
    /// the level theirs is drawn at, so where two cross, theirs wins.
    @Test("shared lines are drawn beneath the hiker's own route")
    func sharedLinesAreUnderneath() async throws {
        let browser = await browserWithLines(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.line()]
        )
        let coordinator = MapView.Coordinator()
        let view = mapView(route: Self.route(), community: browser)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        // The hiker's own route is installed by an update rather than by
        // building the map, which is where a selection reaches MapKit.
        view.update(map, coordinator)
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }

        let shared = try #require(coordinator.communityRoutes.first?.polyline)
        let own = try #require(coordinator.routeOverlay)
        let sharedIndex = try #require(map.overlays.firstIndex { $0 === shared })
        let ownIndex = try #require(map.overlays.firstIndex { $0 === own })
        #expect(sharedIndex < ownIndex, "the hiker's own route draws over a suggestion")
    }

    /// Underneath the hiker's route, but *above the ground* — and the test
    /// above cannot tell the difference, which is how this shipped invisible.
    ///
    /// The lines were added at ``MKOverlayLevel/aboveRoads``, which reads like
    /// "below the route" and is: `map.overlays` walks the levels in order, so
    /// the assertion above held. What it does not mention is that this app
    /// replaces the base map with raster tiles, and that overlay is opaque and
    /// sits at `.aboveLabels` — so everything below it is drawn and then
    /// painted over. A shared hike was built, added and rendered, and buried
    /// under the ground it was drawn on.
    ///
    /// Hence an assertion against the *tile overlay* rather than against a
    /// level: being underneath is a position among the app's own overlays, and
    /// the tiles are the floor of them.
    @Test("shared lines are drawn above the tiles that replace the base map")
    func sharedLinesAreAboveTheBaseMap() async throws {
        let browser = await browserWithLines(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.line()]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }

        let tiles = try #require(coordinator.tileOverlay)
        let shared = try #require(coordinator.communityRoutes.first?.polyline)
        let drawn = map.overlays(in: .aboveLabels)
        let tilesIndex = try #require(drawn.firstIndex { $0 === tiles })
        let sharedIndex = try #require(
            drawn.firstIndex { $0 === shared },
            "a line below the opaque tile overlay is a line nobody can see"
        )
        #expect(sharedIndex > tilesIndex)
    }

    /// The previewed line is appended last so it draws on top, which only
    /// holds if the lines keep their order on the way into MapKit.
    ///
    /// `insertOverlay(_:above:)` inserts *just* above what it is given, so a
    /// loop naming one base for all of them stacks them in reverse — the same
    /// trap `addInferredOverlays` documents.
    @Test("the lines keep their order on the map")
    func linesKeepTheirOrder() async throws {
        let browser = await browserWithLines(
            [.stub(id: "ridge"), .stub(id: "summit", submissionID: "submission-2")],
            outlines: ["ridge": Self.line(), "summit": Self.line(offsetting: 0.02)]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "both lines to reach the map") {
            coordinator.communityRoutes.count == 2
        }

        let drawn = map.overlays(in: .aboveLabels)
        let lines = coordinator.communityRoutes.map(\.polyline)
        let first = try #require(drawn.firstIndex { $0 === lines[0] })
        let second = try #require(drawn.firstIndex { $0 === lines[1] })
        #expect(first < second, "the last line is the one that draws on top")
    }

    /// An identical answer must not drop and re-add every overlay. Without the
    /// guard a block that changed nothing, or a republish of the same page,
    /// would flicker the whole map.
    @Test("republishing the same lines rebuilds nothing")
    func identicalLinesAreNotRebuilt() async throws {
        let browser = await browserWithLines(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.line()]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }
        let first = try #require(coordinator.communityRoutes.first?.polyline)

        coordinator.applyCommunityRoutes(browser.routeLines, on: map)

        #expect(coordinator.communityRoutes.first?.polyline === first)
    }

    // MARK: - Tapping one

    /// MapKit hit-tests annotations and never overlays, so without the
    /// recognizer the lines would be scenery.
    @Test("building the map installs the tap recognizer once")
    func theTapRecognizerIsInstalledOnce() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        let installed = map.gestureRecognizers?.filter { $0 === coordinator.communityRouteTap }
        #expect(installed?.count == 1)

        coordinator.installCommunityRouteTap(on: map)

        let afterSecondCall = map.gestureRecognizers?.filter { recognizer in
            recognizer === coordinator.communityRouteTap
        }
        #expect(afterSecondCall?.count == 1, "a second recognizer would open one preview twice")
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

        let recognizer = try #require(coordinator.communityRouteTap)
        #expect(!recognizer.cancelsTouchesInView, "a callout under the tap has to keep its touch")
        #expect(!recognizer.delaysTouchesEnded, "nothing here needs to arrive before the view's own touch")
        #endif
    }

    /// The gesture this whole file exists for: a thumb on the faded line opens
    /// the hike it belongs to.
    @Test("a tap on a line finds the hike it belongs to")
    func aTapOnALineFindsItsHike() async {
        let browser = await browserWithLines(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.line()]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }
        // The map has to be looking at the line for a screen point to mean
        // anything, and nothing has moved the camera here.
        map.setRegion(Self.communityRegion(), animated: false)
        let onTheLine = map.convert(
            CLLocationCoordinate2D(latitude: Area.latitude, longitude: Area.longitude),
            toPointTo: map
        )

        let listing = coordinator.communityListing(forTapAt: onTheLine, in: map)

        #expect(listing?.id == "ridge")
    }

    /// And the other half: a tap on the map is still a tap on the map.
    @Test("a tap away from every line finds nothing")
    func aTapOnEmptyMapFindsNothing() async {
        let browser = await browserWithLines(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.line()]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }
        map.setRegion(Self.communityRegion(), animated: false)
        let wellAway = map.convert(
            CLLocationCoordinate2D(
                latitude: Area.latitude,
                longitude: Area.longitude + Area.spanMeters / Area.metersPerDegree
            ),
            toPointTo: map
        )

        #expect(coordinator.communityListing(forTapAt: wellAway, in: map) == nil)
    }

    /// Nothing drawn is nothing to find, and the guard is what keeps a tap on
    /// a map with no shared hikes on it from projecting an empty list.
    @Test("a tap finds nothing when no lines are drawn")
    func aTapFindsNothingWithoutLines() {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }

        #expect(coordinator.communityListing(forTapAt: CGPoint(x: 100, y: 100), in: map) == nil)
    }

    /// A recognizer on the map view sees a touch whatever the view under it
    /// does with it, so a tap on the "my location" button would otherwise open
    /// a preview *as well as* recentring the map.
    @Test("a tap on a map control is not a tap on a line")
    func aTapOnAControlIsNotATapOnALine() async throws {
        #if os(iOS)
        let browser = await browserWithLines(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.line()]
        )
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }
        map.setRegion(Self.communityRegion(), animated: false)

        // Put the tracking button squarely on the line, which is the case a
        // hit-test has to resolve and a distance cannot.
        let button = try #require(coordinator.trackingButton)
        let onTheLine = map.convert(
            CLLocationCoordinate2D(latitude: Area.latitude, longitude: Area.longitude),
            toPointTo: map
        )
        #expect(
            coordinator.communityListing(forTapAt: onTheLine, in: map)?.id == "ridge",
            "the line is where the button is about to be"
        )
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = CGRect(x: onTheLine.x - 22, y: onTheLine.y - 22, width: 44, height: 44)

        #expect(coordinator.communityListing(forTapAt: onTheLine, in: map) == nil)
        #endif
    }
}
