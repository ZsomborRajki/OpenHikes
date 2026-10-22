//
//  MapCoordinatorTests+CommunitySearchRegion.swift
//  OpenHikesTests
//
//  Which part of the map *Search this area* is about.
//
//  The community search used to be handed the map's whole region, which runs
//  on under the sheet, and its rows were sorted outward from the middle of
//  that — a point the half-height sheet covers. Every assertion here is about
//  the region handed over instead: measured against the whole view's corners,
//  so what is pinned is the share of the screen the hiker can see rather than
//  any figure MapKit chose for a test map.
//
//  Spans are compared as shares within a couple of per cent rather than
//  exactly, because the map is Mercator and a share of the screen's height is
//  not exactly the same share of its latitude. At these spans the two differ
//  by a fraction of a per cent.
//
//  The pill's tap is the one place the map is read with the sheet wherever it
//  is, and a lowered sheet shows a taller map. A zoom the pill was enabled at
//  can therefore be past the zoom ceiling at the tap, where the search would
//  be refused and the pill left disabled until the map moved. What is pinned
//  there is that the tap asks about the map that enabled the pill instead,
//  and that it does so only when the lowered sheet's map is out of reach.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

extension MapCoordinatorTests {
    /// The slack for a share of the screen read back as a share of a span.
    private static let shareTolerance = 0.02

    /// Berchtesgaden, a tenth of a degree each way.
    private enum Searched {
        static let latitude = 47.63
        static let longitude = 12.86
        static let span = 0.1
    }

    private static let searchedRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: Searched.latitude, longitude: Searched.longitude),
        span: MKCoordinateSpan(latitudeDelta: Searched.span, longitudeDelta: Searched.span)
    )

    /// The span of ``nearTheCeiling``, in degrees.
    private enum Wide {
        static let latitudeSpan = 1.1
        static let longitudeSpan = 0.75
    }

    /// A zoom at which the map above the sheet's middle detent is inside the
    /// zoom ceiling and the map with the sheet lowered is outside it.
    private static let nearTheCeiling = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: Searched.latitude, longitude: Searched.longitude),
        span: MKCoordinateSpan(latitudeDelta: Wide.latitudeSpan, longitudeDelta: Wide.longitudeSpan)
    )

    /// A map showing ``searchedRegion`` unless told otherwise, laid out the
    /// way the suite lays out every map.
    private func searchedMap(
        _ view: MapView,
        _ coordinator: MapView.Coordinator,
        showing region: MKCoordinateRegion = Self.searchedRegion
    ) -> MKMapView {
        let map = makeMap(view, coordinator)
        view.update(map, coordinator)
        map.region = region
        return map
    }

    #if os(iOS)
    /// *Search this area*, which sits inside the pill's glass rather than
    /// among its own subviews.
    private func communitySearchButton(in pill: UIView) -> UIControl? {
        var pending: [UIView] = [pill]
        while let view = pending.popLast() {
            if view.accessibilityIdentifier == MapAreaSearchView.Identifiers.community.button {
                return view as? UIControl
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
    #endif

    /// What share of the whole view's height and width `region` covers.
    ///
    /// Measured against the view's corners rather than against
    /// `MKMapView.region`, which MapKit reads inside the map's layout margins
    /// — a dozen points short of the view on every side here, and the whole
    /// side panel short of it in landscape. The search is about what is on
    /// screen, so its reference is the screen.
    private static func share(of region: MKCoordinateRegion, in map: MKMapView) -> (height: Double, width: Double) {
        let northWest = map.convert(CGPoint(x: map.bounds.minX, y: map.bounds.minY), toCoordinateFrom: map)
        let southEast = map.convert(CGPoint(x: map.bounds.maxX, y: map.bounds.maxY), toCoordinateFrom: map)
        return (
            region.span.latitudeDelta / (northWest.latitude - southEast.latitude),
            region.span.longitudeDelta / (southEast.longitude - northWest.longitude)
        )
    }

    /// One expectation per number of `region`: the same map read through two
    /// routes comes out identical, so the tolerance is only for rounding.
    private static func expectSameRegion(
        _ region: MKCoordinateRegion,
        as expected: MKCoordinateRegion,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let same = 1e-9
        let figures = [
            (region.center.latitude, expected.center.latitude),
            (region.center.longitude, expected.center.longitude),
            (region.span.latitudeDelta, expected.span.latitudeDelta),
            (region.span.longitudeDelta, expected.span.longitudeDelta),
        ]
        for (actual, wanted) in figures {
            #expect(
                actual.isApproximatelyEqual(to: wanted, absoluteTolerance: same),
                sourceLocation: sourceLocation
            )
        }
    }

    /// What the tests at the ceiling stand on: the sheet's middle detent shows
    /// a map the search takes and its lowest detent one it does not. Without
    /// it each of them would pass at any zoom at all, and the numbers are in
    /// the message so that a zoom MapKit lays out differently can be re-chosen.
    private static func expectStraddlesTheCeiling(
        lowered: MKCoordinateRegion,
        middle: MKCoordinateRegion,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let ceiling = CommunityQueryPolicy.maximumRadiusMeters
        let loweredRadius = CommunityQueryPolicy.visibleRadiusMeters(for: lowered)
        let middleRadius = CommunityQueryPolicy.visibleRadiusMeters(for: middle)
        let radii = "\(Int(middleRadius)) m at the middle detent, \(Int(loweredRadius)) m lowered"
        #expect(
            middleRadius <= ceiling && ceiling < loweredRadius,
            "precondition: \(radii), against a ceiling of \(Int(ceiling)) m",
            sourceLocation: sourceLocation
        )
    }

    /// The launch case: no sheet has been watched coming to rest yet, so the
    /// middle detent is the pessimistic guess the camera already uses.
    @Test("the search is told about the map above the sheet, not the whole view")
    func theSearchRegionStopsAtTheSheet() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(), coordinator)
        defer { detach(map) }
        #expect(sheetMetrics.middleRestY == nil, "precondition: nothing has watched a sheet")

        let region = coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent)

        let share = Self.share(of: region, in: map)
        let visible = 1 - MapView.Coordinator.assumedMiddleDetentShare
        let middleOfWindow = map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.midY), toCoordinateFrom: map)
        #expect(share.height.isApproximatelyEqual(to: visible, absoluteTolerance: Self.shareTolerance))
        #expect(share.width.isApproximatelyEqual(to: 1, absoluteTolerance: Self.shareTolerance))
        #expect(
            region.center.latitude > middleOfWindow.latitude,
            "the middle of what is visible is north of the middle of the window, which the sheet covers"
        )
        #endif
    }

    @Test("a measured middle detent decides where the searched map ends")
    func theMeasuredRestDecides() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(), coordinator)
        defer { detach(map) }
        let middle = 0.45
        settle(sheetMetrics, at: map.bounds.height * middle)

        let region = coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent)

        let height = Self.share(of: region, in: map).height
        #expect(height.isApproximatelyEqual(to: middle, absoluteTolerance: Self.shareTolerance))
        #endif
    }

    /// The pill is at the top of the map in every detent, so a hiker can ask
    /// with the sheet lowered — and then they are looking at nearly all of it.
    @Test("at the pill's tap a lowered sheet gives back the map it uncovered")
    func aLoweredSheetWidensTheTap() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(), coordinator)
        defer { detach(map) }
        let middle = 0.45
        settle(sheetMetrics, at: map.bounds.height * middle)
        let lowered = map.bounds.height - 100
        sheetMetrics.report(topY: lowered, atMiddleDetent: false)

        let atTap = Self.share(of: coordinator.communitySearchRegion(of: map, sheet: .whereItIs), in: map)
        let atSettle = Self.share(of: coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent), in: map)

        let uncovered = Double(lowered / map.bounds.height)
        #expect(atTap.height.isApproximatelyEqual(to: uncovered, absoluteTolerance: Self.shareTolerance))
        #expect(
            atSettle.height.isApproximatelyEqual(to: middle, absoluteTolerance: Self.shareTolerance),
            "a settle still measures above the middle detent — that is the map the list is read against"
        )
        #endif
    }

    /// A full-height sheet leaves no map on screen; the map the hiker comes
    /// back to is the one above the middle detent.
    @Test("a sheet raised past its middle detent counts as its middle detent")
    func aRaisedSheetCountsAsTheMiddle() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(), coordinator)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        sheetMetrics.report(topY: map.bounds.height * 0.1, atMiddleDetent: false)

        let atTap = coordinator.communitySearchRegion(of: map, sheet: .whereItIs)
        let atSettle = coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent)

        let same = 1e-9
        #expect(atTap.span.latitudeDelta.isApproximatelyEqual(to: atSettle.span.latitudeDelta, absoluteTolerance: same))
        #expect(atTap.center.latitude.isApproximatelyEqual(to: atSettle.center.latitude, absoluteTolerance: same))
        #endif
    }

    /// Landscape has no sheet: the panel takes the leading edge and the map
    /// beside it is visible from top to bottom.
    @Test("beside the side panel the search keeps the full height and loses the panel's width")
    func theSidePanelTakesTheLeadingEdge() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(sidePanelInset: MapSidePanelLayout.mapInset), coordinator)
        defer { detach(map) }
        let panel = coordinator.obstructionInsets(in: map).left
        #expect(panel >= MapSidePanelLayout.mapInset, "precondition: the panel is on the left")

        let region = coordinator.communitySearchRegion(of: map, sheet: .whereItIs)

        let share = Self.share(of: region, in: map)
        let expected = Double((map.bounds.width - panel) / map.bounds.width)
        #expect(share.height.isApproximatelyEqual(to: 1, absoluteTolerance: Self.shareTolerance))
        #expect(share.width.isApproximatelyEqual(to: expected, absoluteTolerance: Self.shareTolerance))
        #endif
    }

    /// The plumbing end to end: the settle the coordinator already makes is
    /// what reaches the transport, rectangle and all.
    @Test("a settle hands the browser the map above the sheet, and a search asks about it")
    func theSettledRegionReachesTheSearch() async throws {
        #if os(iOS)
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(community: browser), coordinator)
        defer { detach(map) }

        coordinator.mapView(map, regionDidChangeAnimated: false)
        browser.startBrowsing()
        await settle(until: "the search to be asked") { !transport.recording.nearbyRequests.isEmpty }

        let asked = try #require(transport.recording.nearbyRequests.last)
        let expected = coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent)
        let span = try #require(asked.visibleSpan)
        let same = 1e-9
        #expect(span.latitudeDelta.isApproximatelyEqual(to: expected.span.latitudeDelta, absoluteTolerance: same))
        #expect(span.longitudeDelta.isApproximatelyEqual(to: expected.span.longitudeDelta, absoluteTolerance: same))
        #expect(asked.latitude.isApproximatelyEqual(to: expected.center.latitude, absoluteTolerance: same))
        #expect(asked.longitude.isApproximatelyEqual(to: expected.center.longitude, absoluteTolerance: same))
        #endif
    }

    /// The zoom ceiling is a rule about the map a search is asked about, and
    /// the sheet at its lowest detent shows a taller one than at its middle,
    /// so a zoom the pill was enabled at can be over the ceiling by the time
    /// it is tapped.
    @Test("a tap whose lowered-sheet map is over the ceiling asks about the middle detent's map")
    func aTapPastTheCeilingFallsBackToTheMiddleDetent() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(), coordinator, showing: Self.nearTheCeiling)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        sheetMetrics.report(topY: map.bounds.height - 100, atMiddleDetent: false)
        let lowered = coordinator.communitySearchRegion(of: map, sheet: .whereItIs)
        let middle = coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent)
        Self.expectStraddlesTheCeiling(lowered: lowered, middle: middle)

        Self.expectSameRegion(coordinator.communitySearchRegionForTap(of: map), as: middle)
        #endif
    }

    @Test("a tap whose lowered-sheet map is inside the ceiling asks about what the hiker sees")
    func aTapWithinTheCeilingKeepsTheLoweredMap() {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(), coordinator)
        defer { detach(map) }
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        sheetMetrics.report(topY: map.bounds.height - 100, atMiddleDetent: false)
        let lowered = coordinator.communitySearchRegion(of: map, sheet: .whereItIs)
        let middle = coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent)
        #expect(CommunityQueryPolicy.isWithinCeiling(lowered), "precondition: the zoom is far from the ceiling")
        #expect(lowered.span.latitudeDelta > middle.span.latitudeDelta, "precondition: the lowered sheet shows more")

        Self.expectSameRegion(coordinator.communitySearchRegionForTap(of: map), as: lowered)
        #endif
    }

    /// The hole this closes, end to end: with the sheet at its middle detent
    /// the pill is enabled, lowering the sheet puts the map it shows over the
    /// ceiling, and the tap used to settle on *that* — which disabled the very
    /// pill it had been pressed on, asked nothing, and left the browser
    /// holding a region it refuses until the map moved.
    @Test("an enabled pill searches, whatever the sheet has done to the zoom ceiling since")
    func anEnabledPillSearchesPastTheCeiling() async throws {
        #if os(iOS)
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        let coordinator = MapView.Coordinator()
        let map = searchedMap(mapView(community: browser), coordinator, showing: Self.nearTheCeiling)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)
        let button = try #require(communitySearchButton(in: pill))
        settle(sheetMetrics, at: map.bounds.height * 0.45)
        coordinator.mapView(map, regionDidChangeAnimated: false)
        browser.startBrowsing()
        await settle(until: "the first search to be asked") { !transport.recording.nearbyRequests.isEmpty }
        await settle(until: "the first search to finish") { !browser.isSearching && browser.requestsInFlight == 0 }
        await settle(until: "the pill to be enabled") { pill.isEnabled && !pill.isSearching }
        let asked = transport.recording.nearbyRequests.count

        sheetMetrics.report(topY: map.bounds.height - 100, atMiddleDetent: false)
        let lowered = coordinator.communitySearchRegion(of: map, sheet: .whereItIs)
        let middle = coordinator.communitySearchRegion(of: map, sheet: .atMiddleDetent)
        Self.expectStraddlesTheCeiling(lowered: lowered, middle: middle)
        button.sendActions(for: .primaryActionTriggered)

        await settle(until: "the tap's search to be asked") { transport.recording.nearbyRequests.count > asked }
        let area = try #require(transport.recording.nearbyRequests.last)
        let span = try #require(area.visibleSpan)
        let same = 1e-9
        #expect(span.latitudeDelta.isApproximatelyEqual(to: middle.span.latitudeDelta, absoluteTolerance: same))
        #expect(span.longitudeDelta.isApproximatelyEqual(to: middle.span.longitudeDelta, absoluteTolerance: same))
        #expect(area.latitude.isApproximatelyEqual(to: middle.center.latitude, absoluteTolerance: same))
        #expect(area.longitude.isApproximatelyEqual(to: middle.center.longitude, absoluteTolerance: same))
        await settle(until: "the pill to answer again") { pill.isEnabled && !pill.isSearching }

        // A return to the tab re-reads the region the browser last held, so
        // that region has to be one the pill can search.
        browser.stopBrowsing()
        browser.startBrowsing()
        #expect(browser.areaPrompt != .zoomIn)
        #endif
    }
}
