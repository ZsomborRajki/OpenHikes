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

    /// Waits for the browser to leave a request in flight, rather than for a
    /// duration — the house rule is to wait on the effect.
    private func settle(_ browser: CommunityBrowser) async {
        while browser.state == .loading || browser.state == .refreshing {
            await Task.yield()
        }
    }

    /// The whole bargain of the chip: a walker who never taps it never puts a
    /// request on the radio.
    @Test("panning asks nothing until the chip is tapped")
    func panningIsFreeUntilOptedIn() {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport)
        for latitude in [47.6, 48.0, 48.4, 48.8] {
            browser.regionDidSettle(Self.region(latitude: latitude))
        }
        #expect(transport.recording.nearbyRequests.isEmpty)
        #expect(browser.issuedRequests == 0)
    }

    @Test("tapping the chip asks about where the map already is")
    func chipAsksAboutTheCurrentRegion() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(browser.listings.count == 1)
        #expect(browser.state == .loaded)
    }

    /// The map-driven half: with the chip on, panning far enough re-queries
    /// without the walker doing anything.
    @Test("a pan past the threshold re-queries on its own")
    func panningRequeriesWhileBrowsing() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        browser.regionDidSettle(Self.region(latitude: 48.03))
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 2)
    }

    /// Results that were true when they arrived are better than an error
    /// where a list was, so a failed refresh keeps the rows and says so
    /// separately.
    @Test("a failed refresh keeps the rows already on screen")
    func failureKeepsResults() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .failure(.unreachable)
        browser.regionDidSettle(Self.region(latitude: 48.03))
        await settle(browser)

        #expect(browser.listings.count == 1)
        #expect(browser.state == .failed(.unreachable))
    }

    /// A region that failed must stay askable, or the walker's only recourse
    /// is to pan away and back.
    @Test("retrying asks about the failed region again")
    func retryReopensTheRegion() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .failure(.unreachable)
        let browser = CommunityBrowser(transport: transport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        #expect(transport.recording.nearbyRequests.count == 1)

        transport.listingsResult = .success([.stub()])
        browser.retry()
        await settle(browser)

        #expect(transport.recording.nearbyRequests.count == 2)
        #expect(browser.listings.count == 1)
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

        let browser = CommunityBrowser(transport: transport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()

        // The second question, asked while the first is still held open.
        transport.listingsResult = .success([.stub(id: "new")])
        browser.regionDidSettle(Self.region(latitude: 48.03))
        await gate.open()
        await settle(browser)

        #expect(browser.listings.map(\.id) == ["new"])
    }

    @Test("switching the chip off clears the list")
    func stoppingClearsResults() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        browser.stopBrowsing()
        #expect(browser.listings.isEmpty)
        #expect(browser.state == .idle)
        #expect(!browser.isBrowsing)
    }

    /// Typing a trail's name is asking for it by name, wherever the walker is
    /// and whether or not the map layer is on.
    @Test("a typed query searches without the chip")
    func titleSearchNeedsNoChip() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport)
        browser.search(matching: "  Pilis  ")
        await settle(browser)

        #expect(transport.recording.titleQueries == ["Pilis"])
        #expect(browser.listings.count == 1)
    }

    /// The nearby browse and the typed search write to one list, so clearing
    /// the field has to put the map's own answer back rather than leave the
    /// title matches standing under the *Nearby* heading.
    @Test("clearing the query while browsing asks the map's question again")
    func clearingQueryRestoresNearby() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "nearby")])
        let browser = CommunityBrowser(transport: transport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        transport.listingsResult = .success([.stub(id: "typed")])
        browser.search(matching: "Pilis")
        await settle(browser)
        #expect(browser.listings.map(\.id) == ["typed"])

        transport.listingsResult = .success([.stub(id: "nearby")])
        browser.search(matching: "")
        await settle(browser)

        #expect(browser.listings.map(\.id) == ["nearby"])
    }

    /// With the chip off there is no map question to fall back on, so an
    /// emptied field simply leaves nothing.
    @Test("clearing the query without the chip empties the list")
    func clearingQueryWithoutBrowsingEmpties() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport)
        browser.search(matching: "Pilis")
        await settle(browser)
        #expect(!browser.listings.isEmpty)

        browser.search(matching: "   ")
        #expect(browser.listings.isEmpty)
    }

    @Test("a launch with no transport does nothing at all")
    func absentTransportIsInert() {
        let browser = CommunityBrowser(transport: nil)
        #expect(!browser.hasTransport)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        browser.search(matching: "Pilis")
        #expect(browser.issuedRequests == 0)
        #expect(browser.listings.isEmpty)
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
