//
//  MapCoordinatorTests+AreaSearch.swift
//  OpenHikesTests
//
//  *Search this area* arrives and leaves on a quarter-second fade, and a fade
//  is the one thing about this control that a second application of the same
//  state destroys: the animated branch defers `isHidden` to its completion so
//  the pill has something to fade out, and an unanimated apply running behind
//  it in the same main-actor turn hides the view before the animation has
//  drawn a frame.
//
//  So what is asserted here is the half of the behaviour that outlives the
//  animation: the pill is still in the hierarchy while the fade-out runs, and
//  it is out of the way of the map's hit tests once the fade has landed.
//  Whether the quarter-second actually *looks* like a fade is a device pass.
//
//  What raises and withdraws it is the *Community* tab rather than the offer —
//  see ``MapSheetList`` — so the fade is driven here by leaving the tab, and
//  the offer's own comings and goings are asserted on the one thing they still
//  decide: whether a tap can ask anything.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    private static let metersPerDegree: Double = 111_320

    private static func areaRegion(
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        spanMeters: Double = 20_000
    ) -> MKCoordinateRegion {
        let degrees = spanMeters / metersPerDegree
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    /// A browser that has opted in and answered once, so the next pan past the
    /// threshold is an offer rather than a question.
    private func browsingBrowser() async -> CommunityBrowser {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.areaRegion())
        browser.startBrowsing()
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
        return browser
    }

    @Test("the pill stays in the hierarchy until its fade-out has landed")
    func areaPillFadesOutRatherThanVanishing() async throws {
        #if os(iOS)
        let browser = await browsingBrowser()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)

        // The tab is up, so the pill is: it belongs to the community list
        // rather than to any one offer.
        await settle(until: "the pill to be raised") { !pill.isHidden }
        #expect(pill.alpha == 1)
        #expect(pill.isUserInteractionEnabled)

        // Leaving the tab withdraws it. Interaction goes at once — the map
        // underneath is being panned — but the view itself belongs to the
        // animation until the animation is done with it.
        browser.stopBrowsing()
        await settle(until: "the fade-out to start") { !pill.isUserInteractionEnabled }
        #expect(
            !pill.isHidden,
            "hiding the pill in the same turn leaves the fade nothing to fade"
        )

        await settle(until: "the fade-out to land") { pill.isHidden }
        #expect(pill.alpha == 0)
        #endif
    }

    /// Taking the offer used to take the button with it, which put the one
    /// control this list has somewhere the hiker had to earn by panning. It
    /// stays, and asking again is a thing they can do.
    @Test("taking the offer leaves the pill where it is")
    func areaPillOutlivesTheOffer() async throws {
        #if os(iOS)
        let browser = await browsingBrowser()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)

        browser.regionDidSettle(Self.areaRegion(latitude: 48.03))
        await settle(until: "the offer to be raised") { browser.areaPrompt == .search }
        browser.searchVisibleArea()
        await settle(until: "the offer to be taken") { browser.areaPrompt == .settled }

        #expect(!pill.isHidden)
        #expect(pill.isUserInteractionEnabled)
        #expect(pill.isEnabled, "an answered area is still an area worth asking about again")
        #endif
    }

    /// The one state it cannot answer in. Disabled rather than withdrawn: the
    /// list's footer says why, and a control that vanished at a zoom level
    /// would be reporting policy by absence — the thing this pill exists to
    /// stop.
    @Test("above the ceiling the pill stays up and stops answering")
    func areaPillDimsAboveTheCeiling() async throws {
        #if os(iOS)
        let browser = await browsingBrowser()
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(community: browser), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.areaSearchControl)

        browser.regionDidSettle(Self.areaRegion(spanMeters: 2_000_000))
        await settle(until: "the pill to be disabled") { !pill.isEnabled }
        #expect(!pill.isHidden, "the footer explains a dimmed pill, not a missing one")

        browser.regionDidSettle(Self.areaRegion(latitude: 48.03))
        await settle(until: "the pill to answer again") { pill.isEnabled }
        #endif
    }
}
