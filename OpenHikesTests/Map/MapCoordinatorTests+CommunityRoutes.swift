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
//  so the way in has to be found by hand — the half of that which knows what a
//  shared hike is lives here, and the gesture and the order it asks the two
//  kinds of line in are in `MapCoordinatorTests+RouteTap.swift`. And a line is
//  rebuilt wholesale, so the guard against churning every overlay on an
//  identical answer is load bearing rather than a nicety.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
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
        /// How much wider than the searched region a camera has to be for the
        /// whole of a drawn line to be inside it — see
        /// `aPreviewFramesARouteThatWasAlreadyVisible`.
        static let wideningFactor = 4.0
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

    /// Opening a preview frames its route, and does so even when all of that
    /// route is already inside the visible rect.
    ///
    /// The condition this replaces was "move only if part of it runs off the
    /// edge", which sounds like restraint and behaved like a bug. "On screen"
    /// meant on screen *including the part behind the sheet*, so the case it
    /// fired in most was a short route sitting under the panel the hiker had
    /// just opened — and what they reported was not "it moved when it need not
    /// have" but "it never zooms into the new hike's route".
    ///
    /// The precondition is what makes this test the old behaviour's opposite
    /// rather than a repeat of the fit tests: the camera starts wide enough to
    /// contain the whole line, which is exactly when nothing used to happen.
    @Test("opening a preview frames a route that was already fully on screen")
    func aPreviewFramesARouteThatWasAlreadyVisible() async throws {
        #if os(iOS)
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browserWithLines([listing], outlines: ["ridge": Self.line()])
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        await settle(until: "the line to reach the map") {
            !coordinator.communityRoutes.isEmpty
        }
        var wide = Self.communityRegion()
        wide.span.latitudeDelta *= Area.wideningFactor
        wide.span.longitudeDelta *= Area.wideningFactor
        map.setRegion(wide, animated: false)
        let outline = try #require(coordinator.communityRoutes.first?.polyline)
        #expect(
            map.visibleMapRect.contains(outline.boundingMapRect),
            "precondition: the whole route is on screen before the preview opens"
        )
        let before = map.visibleMapRect

        browser.previewOpened(listing)
        browser.previewLoaded(Self.line(), of: listing)
        // Waited on the camera rather than on the line, because the line
        // arriving is what *asks* for the move: a run that checked only for
        // `isPreviewed` would pass on the old behaviour too.
        await settle(until: "the map to frame the preview") {
            coordinator.communityRoutes.first?.line.isPreviewed == true
                && before.size.height != map.visibleMapRect.size.height
        }

        let previewed = try #require(coordinator.communityRoutes.first?.polyline)
        let rect = previewed.boundingMapRect
        let north = map.convert(MKMapPoint(x: rect.minX, y: rect.minY).coordinate, toPointTo: map)
        let south = map.convert(MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate, toPointTo: map)
        let sheetTop = map.bounds.height
            * (1 - MapView.Coordinator.assumedMiddleDetentShare)
        #expect(max(north.y, south.y) <= sheetTop, "and frames it into the map the sheet is not over")
        #expect(min(north.y, south.y) >= 0)
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
    //
    // The recognizer itself, the claim check and the order the two kinds of
    // line are asked in belong to `MapCoordinatorTests+RouteTap.swift`, which
    // is where they moved when the hiker's own route became tappable too.
    // What is left here is the half that knows what a shared hike is.

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
}
