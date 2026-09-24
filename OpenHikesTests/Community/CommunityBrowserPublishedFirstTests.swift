//
//  CommunityBrowserPublishedFirstTests.swift
//  OpenHikesTests
//
//  The published hikes go up while the OpenStreetMap trails are still coming,
//  and the search is not over until they have.
//
//  Its own file for the reason the route-lines suite has one: a different
//  question about the same object — not *what* a nearby answer draws but *in
//  what order it arrives* — and every case here holds the curated half open,
//  which none of the other suites do.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// What a *Search this area* tap draws while Overpass is still thinking.
@MainActor
@Suite("Community browser published hikes first")
struct CommunityBrowserPublishedFirstTests {
    private static func region() -> MKCoordinateRegion {
        let degrees = 20_000 / 111_320.0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    private static let outline = [
        RouteCoordinate(latitude: 47.63, longitude: 12.86),
        RouteCoordinate(latitude: 47.64, longitude: 12.87),
    ]

    private static let trail = CommunityListing.stub(
        id: "trail",
        submissionID: "submission-2",
        authorID: "osm"
    )

    private func settle(_ browser: CommunityBrowser) async {
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    /// A browser that has opened the tab and drawn the published half, with
    /// the curated half held behind the returned gate.
    private func publishedHalfDrawn(
        _ published: [CommunityListing] = [.stub(id: "published")],
        blockList: CommunityBlockList = .scratch()
    ) async -> (browser: CommunityBrowser, transport: StubCommunityTransport, gate: AsyncGate) {
        let transport = StubCommunityTransport()
        let gate = AsyncGate()
        transport.listingsResult = .success(published)
        transport.curatedHalf = (rows: [Self.trail], gate: gate)
        transport.outlinesResult = .success(["published": Self.outline, "trail": Self.outline])
        let browser = CommunityBrowser(transport: transport, blockList: blockList)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        while browser.nearbyListings.isEmpty {
            await Task.yield()
        }
        return (browser, transport, gate)
    }

    /// The request: CloudKit answered in a moment and the list sat empty for
    /// the ten seconds Overpass took. The rows go up at once; the spinner does
    /// not come down until the trails have landed beside them.
    @Test("the published hikes are drawn while the search is still running")
    func publishedHikesDrawnWhileSearching() async {
        let (browser, _, gate) = await publishedHalfDrawn()

        #expect(browser.nearbyListings.map(\.id) == ["published"])
        #expect(browser.state == .refreshing, "rows on screen, request in flight")
        #expect(browser.isSearching, "the pill spins until OpenStreetMap has answered")

        await gate.open()
        await settle(browser)

        #expect(browser.nearbyListings.map(\.id) == ["published", "trail"])
        #expect(browser.state == .loaded)
        #expect(!browser.isSearching)
    }

    /// The published lines are drawn with their rows, and the whole answer
    /// asks only about the trails: dropping the lines already on the map and
    /// asking for them again would blink every one of them off and back.
    @Test("the whole answer asks only for the lines it does not have")
    func wholeAnswerKeepsPublishedLines() async {
        let (browser, transport, gate) = await publishedHalfDrawn()
        while browser.routeLines.isEmpty {
            await Task.yield()
        }
        #expect(browser.routeLines.map(\.id) == ["published"])

        await gate.open()
        await settle(browser)

        #expect(transport.recording.outlineRequests == [["published"], ["trail"]])
        #expect(browser.routeLines.map(\.id) == ["published", "trail"])
    }

    /// Kept rows make a return visit free — but these are half an answer, and
    /// keeping them as a whole one would strand the list without its trails
    /// until the hiker thought to search again.
    @Test("leaving the tab before the trails land asks again on return")
    func leavingMidSearchAsksAgain() async {
        let (browser, transport, gate) = await publishedHalfDrawn()

        browser.stopBrowsing()
        await gate.open()
        await settle(browser)
        browser.startBrowsing()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 2)
        #expect(transport.recording.nearbyScopes.last == .withCuratedTrails)
        #expect(browser.nearbyListings.map(\.id) == ["published", "trail"])
    }

    /// A refill after a block supersedes the search still fetching the trails,
    /// so asking for the published hikes alone would quietly cancel them.
    @Test("a block while the trails are coming re-asks for them too")
    func blockMidSearchKeepsTheTrails() async {
        let blocks = CommunityBlockList.scratch()
        let (browser, transport, gate) = await publishedHalfDrawn(
            [.stub(id: "theirs", authorID: "author-1")],
            blockList: blocks
        )

        transport.listingsResult = .success([.stub(id: "somebody-else", authorID: "author-2")])
        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await gate.open()
        await settle(browser)

        #expect(transport.recording.nearbyScopes == [.withCuratedTrails, .withCuratedTrails])
        #expect(browser.nearbyListings.map(\.id) == ["somebody-else", "trail"])
    }

    /// A published half whose lines failed is not a published half with
    /// lines. Before the early rows, one outline request followed the whole
    /// answer; the whole answer still has to ask again for any the first
    /// request did not bring, or a blip leaves the hiker's own hikes lineless.
    @Test("lines the published half failed to get are asked for again")
    func failedEarlyLinesAreAskedAgain() async {
        let transport = StubCommunityTransport()
        let gate = AsyncGate()
        transport.listingsResult = .success([.stub(id: "published")])
        transport.curatedHalf = (rows: [Self.trail], gate: gate)
        transport.outlinesResult = .failure(.unreachable)
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        // The nearby request is held at the gate, so one in flight is it.
        while transport.recording.outlineRequests.isEmpty || browser.requestsInFlight > 1 {
            await Task.yield()
        }

        transport.outlinesResult = .success(["published": Self.outline, "trail": Self.outline])
        await gate.open()
        await settle(browser)

        #expect(transport.recording.outlineRequests == [["published"], ["published", "trail"]])
        #expect(browser.routeLines.map(\.id) == ["published", "trail"])
    }

    /// A failure brings no rows, so it cannot turn the published half on
    /// screen into a whole answer — and a return visit that believed it had
    /// would never ask for the trails.
    @Test("a failed refill over the published half still asks again on return")
    func failedRefillStillAsksAgain() async {
        let blocks = CommunityBlockList.scratch()
        let (browser, transport, gate) = await publishedHalfDrawn(
            [.stub(id: "theirs", authorID: "author-1")],
            blockList: blocks
        )

        transport.listingsResult = .failure(.unreachable)
        blocks.block(.stub(authorID: "author-1"))
        browser.refreshAfterBlock()
        await gate.open()
        await settle(browser)
        #expect(browser.state == .failed(.unreachable))

        browser.stopBrowsing()
        transport.listingsResult = .success([.stub(id: "somebody-else", authorID: "author-2")])
        browser.startBrowsing()
        await settle(browser)

        #expect(transport.recording.nearbyScopes == [.withCuratedTrails, .withCuratedTrails, .withCuratedTrails])
        #expect(browser.nearbyListings.map(\.id) == ["somebody-else", "trail"])
    }
}
