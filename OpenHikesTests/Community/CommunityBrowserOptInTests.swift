//
//  CommunityBrowserOptInTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// Turning the community list on, and the states the tab can be left in
/// before anything has answered.
///
/// Its own suite rather than more of `CommunityBrowserTests`: that one is
/// about the map driving the query once browsing is on, and one file holds
/// one `@Suite`. What is here is the single request nobody confirms twice —
/// selecting the *Community* tab — and the awkward case that follows it,
/// where the map has not said where it is yet and the answer has to wait for
/// a region that may turn out to be one there is nothing to ask about.
@MainActor
@Suite("Community browser opt-in")
struct CommunityBrowserOptInTests {
    private static func region(
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        spanMeters: Double = 20_000
    ) -> MKCoordinateRegion {
        let degrees = spanMeters / 111_320
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    /// Waits on the effect rather than a duration, and on `requestsInFlight`
    /// rather than `state` — the latter reports the nearby request alone. Same
    /// reasoning as `CommunityBrowserTests`.
    private func settle(_ browser: CommunityBrowser) async {
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    /// The one request nobody confirms twice: the tap that opts in is itself
    /// the confirmation.
    @Test("opting in asks about where the map already is")
    func optingInAsksAboutTheCurrentRegion() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(browser.nearbyListings.count == 1)
        #expect(browser.state == .loaded)
    }

    /// A sheet can be opened before the map has ever reported a region, and
    /// the tap that opts in is still the confirmation — so the first region to
    /// arrive is asked about rather than offered, or the hiker is left with a
    /// spinner beside a button asking them to opt in again.
    @Test("opting in before the map has settled asks about the first region")
    func optingInBeforeTheFirstRegionAsks() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.startBrowsing()
        #expect(browser.state == .loading)

        browser.regionDidSettle(Self.region())
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(browser.areaPrompt == .settled)
        #expect(browser.state == .loaded)
    }

    /// And only the first: once it has been asked, the map is back to offering.
    @Test("the region after that one is offered, not asked")
    func onlyTheFirstRegionIsAsked() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.startBrowsing()
        browser.regionDidSettle(Self.region())
        await settle(browser)

        browser.regionDidSettle(Self.region(latitude: 48.03))
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(browser.areaPrompt == .search)
    }

    /// The deferred opt-in's first region can be one there is nothing to ask
    /// about, and then the spinner it put up has nothing behind it.
    ///
    /// ``CommunityBrowser/startBrowsing()`` settles the state itself when the
    /// map has already reported a region above the ceiling; this is the same
    /// intention arriving a moment later, and it has to reach the same place.
    /// A `.loading` with no request in flight is drawn as a header spinner
    /// that never stops, beside a list saying *Zoom in to look here*.
    @Test("a deferred opt-in above the ceiling stops loading")
    func deferredOptInAboveTheCeilingSettles() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.startBrowsing()
        #expect(browser.state == .loading)

        browser.regionDidSettle(Self.region(spanMeters: 2_000_000))
        await settle(browser)

        #expect(browser.areaPrompt == .zoomIn)
        #expect(browser.state == .loaded)
        #expect(transport.recording.nearbyRequests.isEmpty)
    }

    /// And the opt-in is not spent by that, which is the half a narrower fix
    /// would lose: the tap is still the confirmation, so the first region that
    /// clears the ceiling is asked about rather than offered.
    @Test("a deferred opt-in survives a region it could not ask about")
    func deferredOptInOutlastsTheCeiling() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.startBrowsing()
        browser.regionDidSettle(Self.region(spanMeters: 2_000_000))
        await settle(browser)

        browser.regionDidSettle(Self.region())
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(browser.areaPrompt == .settled)
        #expect(browser.state == .loaded)
    }
}
