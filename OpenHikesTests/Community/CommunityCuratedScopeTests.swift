//
//  CommunityCuratedScopeTests.swift
//  OpenHikesTests
//
//  Which taps reach OpenStreetMap, and what the hiker is told when it refuses.
//
//  Its own suite rather than more of `CommunityBrowserTests`, which is about
//  the map driving the query and the two questions not interfering; one file
//  holds one `@Suite`. What is pinned here is a *cost* and a *sentence*, and
//  neither is visible in the rows: a nearby answer looks exactly the same
//  whether it asked Overpass or not, and a rate-limited search looks exactly
//  like an area with no waymarked routes in it. So both are asserted against
//  what the transport was handed and against what the browser publishes for
//  the button to draw.
//
//  The reason the cost is worth a suite: Overpass is volunteer-run, allows a
//  handful of slots per address and answers a busy one with a `429`. Every
//  nearby request used to reach it — opening the tab, retrying, refilling
//  after a block — so a hiker who never touched *Search this area* could still
//  be rate-limited by the app on their behalf. A regression here is silent
//  until somebody else's quota runs out.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// What a nearby request is allowed to ask for, and what a refused curated
/// half puts on screen.
@MainActor
@Suite("Community curated scope")
struct CommunityCuratedScopeTests {
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
    /// rather than `state` — the same reasoning as `CommunityBrowserTests`.
    private func settle(_ browser: CommunityBrowser) async {
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    /// A browser that has opted in and answered once.
    private func browsing(
        _ transport: StubCommunityTransport,
        blocks: CommunityBlockList = .scratch()
    ) async -> CommunityBrowser {
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        return browser
    }
}

// MARK: - Only the tap asks OpenStreetMap

extension CommunityCuratedScopeTests {
    /// The opt-in is one tap standing in for a question nobody typed. It buys
    /// the hikes people published; it does not buy two Overpass round trips.
    @Test("opening the tab asks for the published hikes alone")
    func optingInIsPublishedOnly() async {
        let transport = StubCommunityTransport()
        _ = await browsing(transport)

        #expect(transport.recording.nearbyScopes == [.publishedOnly])
    }

    /// The one tap that asks for both, and the reason the button exists.
    @Test("Search this area asks for the curated trails too")
    func takingTheOfferAsksOverpass() async {
        let transport = StubCommunityTransport()
        let browser = await browsing(transport)

        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.searchVisibleArea()
        await settle(browser)

        #expect(transport.recording.nearbyScopes == [.publishedOnly, .withCuratedTrails])
    }

    /// A tap with no offer standing is the same tap — it goes through
    /// `retry()`, which is also what *Try Again* runs. A retry that dropped
    /// the trails would leave a rate-limited hiker no way back to them but
    /// panning away and returning.
    @Test("a tap with no offer standing still asks for both")
    func retryAsksOverpass() async {
        let transport = StubCommunityTransport()
        let browser = await browsing(transport)

        browser.searchVisibleArea()
        await settle(browser)
        browser.retry()
        await settle(browser)

        #expect(
            transport.recording.nearbyScopes
                == [.publishedOnly, .withCuratedTrails, .withCuratedTrails]
        )
    }

    /// A block is not a hiker asking OpenStreetMap anything, and the curated
    /// rows in the list are unaffected by one — an OSM relation has no author
    /// to block. Re-asking Overpass here would spend two round trips to get
    /// back the same trails.
    @Test("refilling after a block asks for the published hikes alone")
    func blockRefillIsPublishedOnly() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        let browser = await browsing(transport, blocks: blocks)

        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await settle(browser)

        #expect(transport.recording.nearbyScopes == [.publishedOnly, .publishedOnly])
    }
}

// MARK: - While both halves are out

extension CommunityCuratedScopeTests {
    /// The state the pill draws as a spinner. One flag for both halves,
    /// because there is one request: the merge asks CloudKit and Overpass
    /// side by side and comes back when both have answered or failed.
    @Test("a search is in flight until both halves have come back")
    func searchingSpansBothHalves() async {
        let transport = StubCommunityTransport()
        let held = AsyncGate()
        let browser = await browsing(transport)
        #expect(!browser.isSearching)

        transport.beforeListingsReturn = { await held.wait() }
        browser.searchVisibleArea()
        #expect(browser.isSearching, "the question is open until it is answered")

        await held.open()
        await settle(browser)
        #expect(!browser.isSearching)
    }

    /// A tap while one is out cannot answer sooner — `perform` awaits the task
    /// it supersedes before starting — so it can only queue a second listing
    /// pass against a shared quota. The pill is dimmed and spinning while this
    /// is true; this is the guard behind that rather than instead of it.
    @Test("a tap while a search is out spends nothing")
    func aTapDuringASearchIsRefused() async {
        let transport = StubCommunityTransport()
        let held = AsyncGate()
        let browser = await browsing(transport)
        transport.beforeListingsReturn = { await held.wait() }
        browser.searchVisibleArea()
        let issued = browser.issuedRequests

        browser.searchVisibleArea()
        browser.retry()

        #expect(browser.issuedRequests == issued)
        await held.open()
        await settle(browser)
    }
}

// MARK: - What a refusal says

extension CommunityCuratedScopeTests {
    /// The notice the button draws, and the two things that must not happen
    /// beside it: the request is not a failure, and the rows that did arrive
    /// stay where they are.
    @Test("a rate-limited curated half is reported without failing the search")
    func rateLimitIsReportedBesideTheRows() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        transport.curatedOutage = .rateLimited(retryAfter: 60)
        let browser = await browsing(transport)

        browser.searchVisibleArea()
        await settle(browser)

        #expect(browser.curatedOutage == .rateLimited(retryAfter: 60))
        #expect(browser.state == .loaded, "the published half answered, so the search worked")
        #expect(browser.nearbyListings.map(\.id) == ["theirs"])
    }

    /// The published half answering is what clears it, because that is the
    /// question that asked.
    @Test("a search that reaches OpenStreetMap again clears the notice")
    func aGoodSearchClearsTheNotice() async {
        let transport = StubCommunityTransport()
        transport.curatedOutage = .rateLimited(retryAfter: 60)
        let browser = await browsing(transport)
        browser.searchVisibleArea()
        await settle(browser)
        #expect(browser.curatedOutage != nil)

        transport.curatedOutage = nil
        browser.retry()
        await settle(browser)

        #expect(browser.curatedOutage == nil)
    }

    /// The correction that makes the scope worth carrying past the transport.
    /// A published-only request answers `nil` for the curated half because it
    /// never asked — writing that through would take the caption off the
    /// button while the address was still rate-limited, for no better reason
    /// than that the hiker blocked somebody.
    @Test("a published-only refresh leaves a standing notice alone")
    func aPublishedOnlyRefreshKeepsTheNotice() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        transport.curatedOutage = .rateLimited(retryAfter: 60)
        let browser = await browsing(transport, blocks: blocks)
        browser.searchVisibleArea()
        await settle(browser)
        #expect(browser.curatedOutage == .rateLimited(retryAfter: 60))

        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await settle(browser)

        #expect(browser.curatedOutage == .rateLimited(retryAfter: 60))
    }

    /// The caption belongs to the tab that drew it. A limit still running says
    /// so again on the next tap — the source refuses one without a round trip
    /// — and a notice left standing over a list nobody is looking at is a
    /// notice nothing will ever clear.
    @Test("leaving the tab takes the notice with it")
    func leavingTheTabClearsTheNotice() async {
        let transport = StubCommunityTransport()
        transport.curatedOutage = .unavailable
        let browser = await browsing(transport)
        browser.searchVisibleArea()
        await settle(browser)
        #expect(browser.curatedOutage == .unavailable)

        browser.stopBrowsing()

        #expect(browser.curatedOutage == nil)
    }
}
