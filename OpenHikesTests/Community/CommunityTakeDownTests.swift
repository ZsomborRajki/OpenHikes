//
//  CommunityTakeDownTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

/// What a takedown does to the lists the hike was on.
///
/// Its own suite rather than more of `CommunityBrowserBlockingTests`, because
/// the whole point is that the two are not the same shape and the blocking one
/// is the trap: a block hides an author at *read* time, so its rows go without
/// anybody being told, and `refreshAfterBlock()` exists only for the page a
/// block emptied entirely. A takedown deletes one record and nothing filters
/// it, so the row has to be taken off by hand or it sits there describing a
/// database it is no longer in.
@MainActor
@Suite("Community takedown")
struct CommunityTakeDownTests {
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

    private func settle(_ browser: CommunityBrowser) async {
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    /// The row goes, and only that row. A reviewer who unlists one hike is
    /// looking at a list of the others a moment later.
    @Test("a taken-down hike leaves both lists")
    func takingDownRemovesTheRow() async {
        let transport = StubCommunityTransport()
        let taken = CommunityListing.stub(id: "taken-down", authorID: "author-1")
        transport.listingsResult = .success([
            taken,
            .stub(id: "somebody-else", authorID: "author-2"),
        ])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        browser.search(matching: "Pilis")
        await settle(browser)

        browser.forgetTakenDown(taken)

        #expect(browser.nearbyListings.map(\.id) == ["somebody-else"])
        #expect(
            browser.matchingListings.map(\.id) == ["somebody-else"],
            "a typed search holds the same deleted record and is not re-asked either"
        )
    }

    /// The line on the map is drawn through the row, so leaving the outline
    /// behind would keep a trail on screen for a hike nothing can open.
    @Test("its line goes off the map with it")
    func takingDownRemovesTheLine() async {
        let transport = StubCommunityTransport()
        let taken = CommunityListing.stub(id: "taken-down", submissionID: "submission-1")
        transport.listingsResult = .success([taken])
        transport.outlinesResult = .success([
            "taken-down": [
                RouteCoordinate(latitude: 47.63, longitude: 12.86),
                RouteCoordinate(latitude: 47.64, longitude: 12.87),
            ],
        ])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        #expect(!browser.routeLines.isEmpty, "precondition: the hike had a line")

        browser.forgetTakenDown(taken)

        #expect(browser.routeLines.isEmpty)
    }

    /// The failure this is all for: nothing filters a deleted listing, so
    /// without being told, the browser would go on offering a row whose only
    /// possible outcome is *this hike isn't available any more*. A block is
    /// not the precedent — `refreshAfterBlock()` would have asked nothing
    /// here, because the list is not empty.
    @Test("nothing else would have taken the row away")
    func nothingElseRemovesTheRow() async {
        let transport = StubCommunityTransport()
        let taken = CommunityListing.stub(id: "taken-down", authorID: "author-1")
        transport.listingsResult = .success([
            taken,
            .stub(id: "somebody-else", authorID: "author-2"),
        ])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        browser.refreshAfterBlock()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1, "no request to re-ask with")
        #expect(
            browser.nearbyListings.map(\.id) == ["taken-down", "somebody-else"],
            "which is why the takedown has to say so itself"
        )
    }
}
