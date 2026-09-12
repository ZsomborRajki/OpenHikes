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

        // Panned somewhere the list does not describe: the offer is up.
        browser.regionDidSettle(Self.areaRegion(latitude: 48.03))
        await settle(until: "the pill to be offered") { !pill.isHidden }
        #expect(pill.alpha == 1)
        #expect(pill.isUserInteractionEnabled)

        // Taking the offer withdraws it. Interaction goes at once — the map
        // underneath is being panned — but the view itself belongs to the
        // animation until the animation is done with it.
        browser.searchVisibleArea()
        await settle(until: "the fade-out to start") { !pill.isUserInteractionEnabled }
        #expect(
            !pill.isHidden,
            "hiding the pill in the same turn leaves the fade nothing to fade"
        )

        await settle(until: "the fade-out to land") { pill.isHidden }
        #expect(pill.alpha == 0)
        #endif
    }
}
