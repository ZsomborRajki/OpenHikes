//
//  CommunityBrowserBlockingTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// What a blocked author does to the two lists the browser keeps, and what a
/// request is allowed to spend while somebody is blocked.
///
/// Its own suite rather than more of `CommunityBrowserTests`: that one is
/// about the map driving the query and the two questions not interfering, and
/// one file holds one `@Suite`.
@MainActor
@Suite("Community browser blocking")
struct CommunityBrowserBlockingTests {
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

    /// The two lists answer different questions and are kept apart on purpose,
    /// so the one thing they must not disagree about is who is hidden.
    @Test("a blocked author is gone from both result sets")
    func blockingFiltersBothQuestions() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([
            .stub(id: "theirs", authorID: "author-1"),
            .stub(id: "somebody-else", authorID: "author-2"),
        ])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        browser.search(matching: "Pilis")
        await settle(browser)

        blocks.block(.stub(authorID: "author-1"))

        #expect(browser.nearbyListings.map(\.id) == ["somebody-else"])
        #expect(browser.matchingListings.map(\.id) == ["somebody-else"])
    }

    /// The filter is applied where the lists are read rather than where the
    /// results land, which is what makes a block reach rows already on screen
    /// — the case that matters, since blocking is reached from a hike opened
    /// out of one of these lists.
    @Test("a block reaches results that are already on screen")
    func blockingHidesRowsWithoutAnotherRequest() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        let requestsBefore = browser.issuedRequests

        blocks.block(.stub(authorID: "author-1"))

        #expect(browser.nearbyListings.isEmpty)
        #expect(browser.issuedRequests == requestsBefore)
    }

    /// The other half of filtering on read: the rows were hidden rather than
    /// thrown away, so undoing a block does not cost a round trip either.
    @Test("unblocking gives the rows back without asking again")
    func unblockingRestoresRows() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        blocks.block(.stub(authorID: "author-1"))
        let requestsBefore = browser.issuedRequests

        blocks.unblock("author-1")

        #expect(browser.nearbyListings.map(\.id) == ["theirs"])
        #expect(browser.issuedRequests == requestsBefore)
    }

    /// A region whose every row is blocked out draws the same empty state as a
    /// region with nothing in it, which is the honest answer: there is nothing
    /// here for this hiker to see.
    @Test("a region of nothing but blocked hikes still reports loaded")
    func blockingEverythingIsNotAFailure() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        blocks.block(.stub(authorID: "author-1"))
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        #expect(browser.nearbyListings.isEmpty)
        #expect(browser.state == .loaded)
    }

    /// The budget half of blocking: a request must not spend its twenty-five
    /// rows on hikes the hiker will never be shown. See
    /// `CommunityPageBudgetTests` for what the transport does with the set.
    @Test("every request carries the blocked authors with it")
    func requestsCarryTheExclusionSet() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        blocks.block(.stub(authorID: "author-1"))
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        browser.search(matching: "Pilis")
        await settle(browser)

        #expect(transport.recording.exclusions.count == 2)
        #expect(transport.recording.exclusions.allSatisfy { $0 == ["author-1"] })
    }

    /// Blocking one person must not empty the map. A page that was entirely
    /// theirs leaves nothing on screen, and the hiker has no reason to think
    /// panning away and back would help.
    @Test("a block that empties the list asks again")
    func emptyingTheListRefills() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .success([
            .stub(id: "theirs", authorID: "author-1"),
            .stub(id: "somebody-else", authorID: "author-2"),
        ])
        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 2)
        #expect(transport.recording.exclusions.last == ["author-1"])
        #expect(browser.nearbyListings.map(\.id) == ["somebody-else"])
    }

    /// The ordinary block — a few rows out of twenty-five — must not put a
    /// request on the radio. There is still a list to look at.
    @Test("a block that leaves rows standing asks nothing")
    func aPartialBlockDoesNotRefill() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([
            .stub(id: "theirs", authorID: "author-1"),
            .stub(id: "somebody-else", authorID: "author-2"),
        ])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(browser.nearbyListings.map(\.id) == ["somebody-else"])
    }

    // MARK: A block is not an answer to the map's question

    /// The refill used to go through `retry()`, which reads the *latest*
    /// region and commits it. So blocking somebody while the map sat over an
    /// unaccepted pan searched that pan instead: a different area's hikes
    /// replaced the list, and the *Search this area* offer the hiker had not
    /// taken was silently accepted on their behalf.
    @Test("a block refills the area on screen, not wherever the map has drifted")
    func blockRefillsTheAnsweredArea() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        // Pan somewhere else and leave the offer standing, unaccepted.
        browser.regionDidSettle(Self.region(latitude: 48.03))
        #expect(browser.areaPrompt == .search, "precondition: an offer nobody took")

        transport.listingsResult = .success([.stub(id: "somebody-else", authorID: "author-2")])
        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await settle(browser)

        #expect(
            transport.recording.nearbyRequests.last?.coordinate.latitude == 47.63,
            "the refill asks about the area the emptied rows answered"
        )
        #expect(
            browser.areaPrompt == .search,
            "and the offer the hiker never accepted is still theirs to take"
        )
        #expect(browser.nearbyListings.map(\.id) == ["somebody-else"])
    }

    /// The other half of leaving the offer alone: a refill must not spend the
    /// policy's memory of the committed area either, or the pan that is still
    /// on offer would stop being offered.
    @Test("a block refill does not commit the area it re-asks about")
    func blockRefillDoesNotRecommit() async {
        let transport = StubCommunityTransport()
        let blocks = CommunityBlockList.scratch()
        transport.listingsResult = .success([.stub(id: "theirs", authorID: "author-1")])
        let browser = CommunityBrowser(transport: transport, blockList: blocks)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        let committedBefore = browser.issuedRequests

        browser.regionDidSettle(Self.region(latitude: 48.03))
        transport.listingsResult = .success([.stub(id: "somebody-else", authorID: "author-2")])
        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await settle(browser)

        #expect(browser.issuedRequests == committedBefore + 1, "one refill, and only one")
        // Taking the standing offer must still work, and must still be about B.
        browser.searchVisibleArea()
        await settle(browser)
        #expect(transport.recording.nearbyRequests.last?.coordinate.latitude == 48.03)
    }
}
