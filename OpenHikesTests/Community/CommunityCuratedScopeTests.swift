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
//  nearby request used to reach it, refills after a block included — requests
//  nobody made, against somebody else's quota. What is pinned now is the line
//  between the two: the three things a hiker does to reach the trails ask for
//  them, and the request the app makes for itself does not. A regression
//  either way is silent — one spends a stranger's quota, the other opens the
//  trails tab without the trails.
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

// MARK: - A hiker's own taps ask OpenStreetMap

extension CommunityCuratedScopeTests {
    /// Selecting the tab is a hiker asking for the trails, and the tab is
    /// where the trails are. It briefly bought the published hikes alone, and
    /// what that saved was a list that opened looking empty wherever the
    /// OpenStreetMap half was the answer.
    @Test("opening the tab asks for the curated trails too")
    func optingInAsksOverpass() async {
        let transport = StubCommunityTransport()
        _ = await browsing(transport)

        #expect(transport.recording.nearbyScopes == [.withCuratedTrails])
    }

    /// The tap the button exists for, asking about somewhere new.
    @Test("Search this area asks for the curated trails too")
    func takingTheOfferAsksOverpass() async {
        let transport = StubCommunityTransport()
        let browser = await browsing(transport)

        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.searchVisibleArea()
        await settle(browser)

        #expect(transport.recording.nearbyScopes == [.withCuratedTrails, .withCuratedTrails])
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
                == [.withCuratedTrails, .withCuratedTrails, .withCuratedTrails]
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

        #expect(transport.recording.nearbyScopes == [.withCuratedTrails, .publishedOnly])
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

// MARK: - What the caption says

extension CommunityCuratedScopeTests {
    /// The one a hiker meets most often, and the one that used to read as a
    /// broken service. The search worked; there is nothing waymarked near
    /// there; the answer is to look somewhere else, which is what the caption
    /// now says.
    @Test("an area with no OpenStreetMap trails in it captions the pill")
    func anEmptyAreaCaptionsThePill() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "theirs")])
        transport.curatedOutcome = .trails(0)
        let browser = await browsing(transport)

        #expect(browser.curatedNotice == .noTrailsHere)
        #expect(browser.state == .loaded, "an empty half is not a failed search")
        #expect(browser.nearbyListings.map(\.id) == ["theirs"], "the published half is untouched")
    }

    /// The count is the listing pass's, not the page's, so a search that found
    /// trails says nothing even when the merge had no room to draw them.
    @Test("a search that found trails captions nothing")
    func foundTrailsCaptionNothing() async {
        let transport = StubCommunityTransport()
        transport.curatedOutcome = .trails(12)
        let browser = await browsing(transport)

        #expect(browser.curatedNotice == nil)
    }

    /// The notice the button draws, and the two things that must not happen
    /// beside it: the request is not a failure, and the rows that did arrive
    /// stay where they are.
    @Test("a rate-limited curated half is reported without failing the search")
    func rateLimitIsReportedBesideTheRows() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        transport.curatedOutcome = .outage(.rateLimited(retryAfter: 60))
        let browser = await browsing(transport)

        browser.searchVisibleArea()
        await settle(browser)

        #expect(browser.curatedNotice == .outage(.rateLimited(retryAfter: 60)))
        #expect(browser.state == .loaded, "the published half answered, so the search worked")
        #expect(browser.nearbyListings.map(\.id) == ["theirs"])
    }

    /// The published half answering is what clears it, because that is the
    /// question that asked.
    @Test("a search that reaches OpenStreetMap again clears the notice")
    func aGoodSearchClearsTheNotice() async {
        let transport = StubCommunityTransport()
        transport.curatedOutcome = .outage(.rateLimited(retryAfter: 60))
        let browser = await browsing(transport)
        browser.searchVisibleArea()
        await settle(browser)
        #expect(browser.curatedNotice != nil)

        transport.curatedOutcome = .trails(4)
        browser.retry()
        await settle(browser)

        #expect(browser.curatedNotice == nil)
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
        transport.curatedOutcome = .outage(.rateLimited(retryAfter: 60))
        let browser = await browsing(transport, blocks: blocks)
        browser.searchVisibleArea()
        await settle(browser)
        #expect(browser.curatedNotice == .outage(.rateLimited(retryAfter: 60)))

        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await settle(browser)

        #expect(browser.curatedNotice == .outage(.rateLimited(retryAfter: 60)))
    }

    /// The caption belongs to the tab that drew it. A limit still running says
    /// so again on the next tap — the source refuses one without a round trip
    /// — and a notice left standing over a list nobody is looking at is a
    /// notice nothing will ever clear.
    @Test("leaving the tab takes the notice with it")
    func leavingTheTabClearsTheNotice() async {
        let transport = StubCommunityTransport()
        transport.curatedOutcome = .outage(.unavailable)
        let browser = await browsing(transport)
        browser.searchVisibleArea()
        await settle(browser)
        #expect(browser.curatedNotice == .outage(.unavailable))

        browser.stopBrowsing()

        #expect(browser.curatedNotice == nil)
    }
}

// MARK: - Coming back to the tab

/// The cheapest request is the one a return visit does not make, and this is
/// where that was being got wrong.
///
/// The bug these pin: leaving the tab emptied the rows, coming back re-asked as
/// ``CommunityNearbyScope/publishedOnly``, and `publishedOnly` returns from
/// ``MergedCommunityTransport``'s `listCurated` before ``CuratedTrailSource``
/// is consulted at all. So the OpenStreetMap half of a list the hiker had just
/// spent two Overpass round trips on vanished on a switch to *My Hikes* and
/// back, and no cache could have answered it — the question was never put.
extension CommunityCuratedScopeTests {
    /// A search, then a round trip through the other tab.
    ///
    /// The transport's answer is swapped afterwards, so a re-ask would be
    /// visible in the rows rather than only in the recording: this fails on
    /// both counts if the old behaviour comes back.
    private func searchedThenLeftAndReturned(
        _ transport: StubCommunityTransport
    ) async -> (browser: CommunityBrowser, askedBefore: [CommunityNearbyScope]) {
        transport.listingsResult = .success([.stub(id: "curated-1"), .stub(id: "theirs")])
        let browser = await browsing(transport)
        browser.searchVisibleArea()
        await settle(browser)
        let askedBefore = transport.recording.nearbyScopes
        transport.listingsResult = .success([.stub(id: "re-asked")])
        browser.stopBrowsing()
        return (browser, askedBefore)
    }

    @Test("coming back to an unmoved map keeps the trails it already found")
    func returningKeepsTheRows() async {
        let transport = StubCommunityTransport()
        let (browser, askedBefore) = await searchedThenLeftAndReturned(transport)

        browser.startBrowsing()
        await settle(browser)

        #expect(
            transport.recording.nearbyScopes == askedBefore,
            "a return visit to an unmoved map is not a question"
        )
        #expect(browser.nearbyListings.map(\.id).sorted() == ["curated-1", "theirs"])
        #expect(browser.state == .loaded)
    }

    /// The rows are kept; the *drawing* of them is not. The map observes
    /// ``CommunityBrowser/nearbyListings`` and has no other signal, so pins and
    /// lines for a list nobody is looking at would otherwise sit over *My
    /// Hikes*.
    @Test("the pins come off the map while the tab is away")
    func leavingClearsTheMap() async {
        let transport = StubCommunityTransport()
        let (browser, _) = await searchedThenLeftAndReturned(transport)

        #expect(browser.nearbyListings.isEmpty, "nothing of the list is drawn while it is away")
        #expect(browser.routeLines.isEmpty)

        browser.startBrowsing()
        await settle(browser)
        #expect(browser.nearbyListings.map(\.id).sorted() == ["curated-1", "theirs"])
    }

    /// The other half of keeping them: they are kept, not pinned to the
    /// screen. A map that moved while the tab was away is a different question,
    /// and the answer is the offer the hiker already knows — not a silent
    /// replacement of good rows with a published-only list.
    @Test("a map that moved while the tab was away offers the new area")
    func aPanWhileAwayRaisesTheOffer() async {
        let transport = StubCommunityTransport()
        let (browser, askedBefore) = await searchedThenLeftAndReturned(transport)

        // Roughly 44 km north, comfortably past the policy's threshold.
        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.startBrowsing()
        await settle(browser)

        #expect(browser.areaPrompt == .search, "the hiker is offered where they are now")
        #expect(
            transport.recording.nearbyScopes == askedBefore,
            "the offer is an invitation, not a request"
        )
        #expect(
            browser.nearbyListings.map(\.id).sorted() == ["curated-1", "theirs"],
            "the rows still answer about the area they came back for"
        )
    }
}
