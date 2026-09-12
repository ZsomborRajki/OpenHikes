//
//  CommunityBrowserTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// What the map moving does to the community list, and what it must not do.
@MainActor
@Suite("Community browser")
struct CommunityBrowserTests {
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

    /// Waits for the browser to leave nothing in flight, rather than for a
    /// duration — the house rule is to wait on the effect.
    ///
    /// On ``CommunityBrowser/requestsInFlight`` rather than on `state`, which
    /// reports the nearby request only: a title search finishing is invisible
    /// there, and a suite that waited on it would assert about results that
    /// had not arrived.
    private func settle(_ browser: CommunityBrowser) async {
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    /// The whole bargain of the section: a hiker who never asks for it never
    /// puts a request on the radio, and nothing offers to.
    @Test("panning asks nothing until the hiker opts in")
    func panningIsFreeUntilOptedIn() {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        for latitude in [47.6, 48.0, 48.4, 48.8] {
            browser.regionDidSettle(Self.region(latitude: latitude))
        }
        #expect(transport.recording.nearbyRequests.isEmpty)
        #expect(browser.issuedRequests == 0)
        #expect(browser.areaPrompt == .settled)
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

    /// The change this whole design turns on: panning offers, and only the
    /// hiker's tap spends anything. A pan nobody confirms is free.
    @Test("a pan past the threshold offers rather than asks")
    func panningOffersWhileBrowsing() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        browser.regionDidSettle(Self.region(latitude: 48.03))
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(browser.areaPrompt == .search)
    }

    @Test("taking the offer asks about the area that raised it")
    func searchingTheVisibleAreaAsks() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.searchVisibleArea()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 2)
        #expect(transport.recording.nearbyRequests.last?.coordinate.latitude == 48.03)
        // Taken, so there is nothing left to offer.
        #expect(browser.areaPrompt == .settled)
    }

    /// Nothing to take is nothing to spend: the button is not on screen in
    /// this state, and a stray call must not invent a question.
    @Test("searching the visible area does nothing without an offer")
    func searchingWithoutAnOfferIsInert() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        browser.searchVisibleArea()
        await settle(browser)
        #expect(transport.recording.nearbyRequests.count == 1)
    }

    /// Above the ceiling a nearby result means "somewhere on this continent",
    /// so there is nothing to offer and something to say.
    @Test("zoomed out past the ceiling, the map asks the hiker to zoom in")
    func continentalZoomPromptsAZoom() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        browser.regionDidSettle(Self.region(spanMeters: 2_000_000))
        #expect(browser.areaPrompt == .zoomIn)
        browser.searchVisibleArea()
        await settle(browser)
        #expect(transport.recording.nearbyRequests.count == 1)
    }

    /// Results that were true when they arrived are better than an error
    /// where a list was, so a failed refresh keeps the rows and says so
    /// separately.
    @Test("a failed refresh keeps the rows already on screen")
    func failureKeepsResults() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .failure(.unreachable)
        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.searchVisibleArea()
        await settle(browser)

        #expect(browser.nearbyListings.count == 1)
        #expect(browser.state == .failed(.unreachable))
    }

    /// A region that failed must stay askable, or the hiker's only recourse
    /// is to pan away and back.
    @Test("retrying asks about the failed region again")
    func retryReopensTheRegion() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .failure(.unreachable)
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        #expect(transport.recording.nearbyRequests.count == 1)

        transport.listingsResult = .success([.stub()])
        browser.retry()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 2)
        #expect(browser.nearbyListings.count == 1)
    }

    /// Two overlapping round trips can land in either order, and the older one
    /// landing second would leave the list describing a region the map has
    /// already left.
    @Test("a newer region supersedes one still in flight")
    func newerRegionSupersedesOlder() async {
        let transport = StubCommunityTransport()
        let gate = AsyncGate()
        transport.listingsResult = .success([.stub(id: "old")])
        transport.beforeListingsReturn = { await gate.wait() }

        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()

        // The second question, asked while the first is still held open.
        transport.listingsResult = .success([.stub(id: "new")])
        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.searchVisibleArea()
        await gate.open()
        await settle(browser)

        #expect(browser.nearbyListings.map(\.id) == ["new"])
    }

    @Test("hiding the section clears the list")
    func stoppingClearsResults() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        browser.stopBrowsing()
        #expect(browser.nearbyListings.isEmpty)
        #expect(browser.state == .idle)
        #expect(!browser.isBrowsing)
        #expect(browser.areaPrompt == .settled)
        #expect(browser.areaName == nil)
    }

    /// Typing a trail's name is asking for it by name, wherever the hiker is
    /// and whether or not the map layer is on.
    @Test("a typed query searches without opting in")
    func titleSearchNeedsNoOptIn() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "  Pilis  ")
        await settle(browser)

        #expect(transport.recording.titleQueries == ["Pilis"])
        #expect(browser.matchingListings.count == 1)
    }

    /// The two questions keep their own answers, so a typed search never
    /// stands in for the map's.
    @Test("a title search leaves the nearby results alone")
    func titleSearchKeepsNearbyResults() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "nearby")])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .success([.stub(id: "typed")])
        browser.search(matching: "Pilis")
        await settle(browser)

        #expect(browser.matchingListings.map(\.id) == ["typed"])
        #expect(browser.nearbyListings.map(\.id) == ["nearby"])
    }

    /// The reported bug, from the other side: with a title in the field,
    /// panning far enough used to replace what was typed with unrelated
    /// nearby hikes, under a heading that still said *Shared Hikes*.
    @Test("a pan during a title search cannot overwrite the matches")
    func panningKeepsTitleMatches() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "nearby")])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .success([.stub(id: "typed")])
        browser.search(matching: "Pilis")
        await settle(browser)

        transport.listingsResult = .success([.stub(id: "panned")])
        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.searchVisibleArea()
        await settle(browser)

        #expect(browser.matchingListings.map(\.id) == ["typed"])
        #expect(browser.nearbyListings.map(\.id) == ["panned"])
    }

    /// Clearing the field drops the matches and nothing else — including
    /// above the zoom ceiling, where the old fix depended on a replacement
    /// query the policy refuses to make, and so left the title matches on
    /// screen.
    @Test("clearing the query above the zoom ceiling still drops the matches")
    func clearingQueryAboveTheCeilingDropsMatches() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "nearby")])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .success([.stub(id: "typed")])
        browser.search(matching: "Pilis")
        await settle(browser)

        // Zoomed out past 150 km, where the policy refuses to ask anything.
        browser.regionDidSettle(Self.region(spanMeters: 600_000))
        await settle(browser)
        browser.search(matching: "")
        await settle(browser)

        #expect(browser.matchingListings.isEmpty)
        #expect(browser.nearbyListings.map(\.id) == ["nearby"])
    }

    /// A typed search belongs to the field rather than to the section, so
    /// hiding the section takes the map's answer and leaves the hiker's own
    /// question standing.
    @Test("hiding the section keeps the title matches")
    func stoppingKeepsTitleMatches() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "nearby")])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .success([.stub(id: "typed")])
        browser.search(matching: "Pilis")
        await settle(browser)

        browser.stopBrowsing()
        #expect(browser.nearbyListings.isEmpty)
        #expect(browser.matchingListings.map(\.id) == ["typed"])
    }

    /// An emptied field leaves nothing of the search behind.
    @Test("clearing the query empties the matches")
    func clearingQueryEmptiesMatches() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "Pilis")
        await settle(browser)
        #expect(!browser.matchingListings.isEmpty)

        browser.search(matching: "   ")
        #expect(browser.matchingListings.isEmpty)
    }

    /// A failed title search has nowhere to report itself and must not
    /// borrow the nearby list's place to do it.
    @Test("a failed title search leaves the nearby state alone")
    func failedTitleSearchKeepsNearbyState() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "nearby")])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .failure(.unreachable)
        browser.search(matching: "Pilis")
        await settle(browser)

        #expect(browser.state == .loaded)
        #expect(browser.nearbyListings.map(\.id) == ["nearby"])
    }

    @Test("a launch with no transport does nothing at all")
    func absentTransportIsInert() {
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        #expect(!browser.hasTransport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        browser.search(matching: "Pilis")
        #expect(browser.issuedRequests == 0)
        #expect(browser.nearbyListings.isEmpty)
        #expect(browser.matchingListings.isEmpty)
    }
}

/// A one-shot barrier a stub can block on, so a suite can hold one request
/// open while it starts another.
///
/// An actor rather than a semaphore because the thing being held is an `await`
/// inside a `Task`, and blocking a thread there would deadlock the executor
/// rather than delay the call.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
