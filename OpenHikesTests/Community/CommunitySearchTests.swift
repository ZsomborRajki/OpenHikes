import Foundation
import MapKit
@testable import OpenHikes
import Testing

@MainActor
@Suite("Community search areas")
struct CommunitySearchTests {
    private static let origin = CLLocationCoordinate2D(latitude: 47.7, longitude: 18.9)
    private static let other = CLLocationCoordinate2D(latitude: 48.7, longitude: 19.9)
    private static let diameter: Double = 20_000

    private func region(_ coordinate: CLLocationCoordinate2D = Self.origin) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: Self.diameter, longitudinalMeters: Self.diameter)
    }

    private func settle(_ browser: CommunityBrowser) async {
        await settleDelegateHop(until: "community requests finish") { browser.requestsInFlight == 0 }
        #expect(browser.requestsInFlight == 0)
    }

    @Test("title and area are combined before the transport spends its limit")
    func combinedSearchStaysInCommittedArea() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.selectArea(.place("Pilis"), region: region())
        browser.startBrowsing()
        browser.search(matching: "Ridge", inSelectedArea: true)
        await settle(browser)
        browser.regionDidSettle(region(Self.other))
        browser.search(matching: "Forest", inSelectedArea: true)
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Ridge", "Forest"])
        #expect(transport.recording.titleAreas.allSatisfy { $0?.latitude == Self.origin.latitude })
        #expect(browser.canSearchThisArea)
        browser.searchThisArea()
        await settle(browser)
        #expect(transport.recording.titleAreas.last??.latitude == Self.other.latitude)
        #expect(browser.areaChoice == .map)
    }

    @Test("Anywhere removes the geographic constraint and an empty query spends nothing")
    func anywhereSearch() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.selectArea(.anywhere)
        browser.startBrowsing()
        browser.search(matching: "", inSelectedArea: true)
        await settle(browser)
        #expect(browser.issuedRequests == 0)
        browser.search(matching: "Ridge", inSelectedArea: true)
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Ridge"])
        #expect(transport.recording.titleAreas.count == 1)
        #expect(transport.recording.titleAreas[0] == nil)
    }

    @Test("retrying a title failure uses its committed area, not the moved map")
    func retryKeepsAreaAndQuery() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .failure(.unreachable)
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.selectArea(.nearMe, region: region())
        browser.startBrowsing()
        browser.search(matching: "Ridge", inSelectedArea: true)
        await settle(browser)
        #expect(browser.matchingState == .failed(.unreachable))
        browser.regionDidSettle(region(Self.other))
        transport.listingsResult = .success([.stub()])
        browser.retryTitleSearch()
        await settle(browser)
        #expect(browser.matchingState == .loaded)
        #expect(transport.recording.titleQueries == ["Ridge", "Ridge"])
        #expect(transport.recording.titleAreas.last??.latitude == Self.origin.latitude)
    }

    @Test("new fragments clear old matches and cancelled fragments never reach the transport")
    func debounceAndClear() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "P")
        browser.search(matching: "Pi")
        browser.search(matching: "Pilis")
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis"])
        #expect(browser.matchingListings.count == 1)
        transport.listingsResult = .failure(.unreachable)
        browser.search(matching: "Forest")
        #expect(browser.matchingListings.isEmpty)
        await settle(browser)
        #expect(browser.matchingState == .failed(.unreachable))
        #expect(browser.matchingListings.isEmpty)
    }

    @Test("a broad area never falls back to a worldwide title search")
    func zoomCeiling() async {
        let transport = StubCommunityTransport()
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        let broadDiameter: Double = 800_000
        let broad = MKCoordinateRegion(
            center: Self.origin, latitudinalMeters: broadDiameter, longitudinalMeters: broadDiameter
        )
        browser.selectArea(.place("Europe"), region: broad)
        browser.startBrowsing()
        browser.search(matching: "Ridge", inSelectedArea: true)
        await settle(browser)
        #expect(browser.needsZoom)
        #expect(browser.issuedRequests == 0)
        browser.regionDidSettle(region())
        #expect(browser.canSearchThisArea)
        browser.searchThisArea()
        await settle(browser)
        #expect(!browser.needsZoom)
        #expect(transport.recording.titleQueries == ["Ridge"])
    }

    @Test("clearing an area-filtered title restores browse results")
    func clearTitleRestoresBrowse() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "Ridge", inSelectedArea: true)
        browser.regionDidSettle(region())
        browser.startBrowsing()
        await settle(browser)
        #expect(transport.recording.nearbyRequests.isEmpty)
        browser.search(matching: "", inSelectedArea: true)
        await settle(browser)
        #expect(browser.state == .loaded)
        #expect(browser.nearbyListings.count == 1)
        #expect(browser.matchingListings.isEmpty)
    }

    /// The UI fixture stands in for ``CloudKitCommunityTransport``, so it has
    /// to spend its budget the same way: on rows that satisfy *both*
    /// predicates. Truncating the area first would hide a matching title
    /// behind non-matching rows and make the scenarios above agree with a
    /// transport that had stopped combining them.
    @Test("the UI fixture applies both predicates before the result budget")
    func fixtureCombinesBeforeTheLimit() async throws {
        let fixture = CommunitySearchFixture()
        let area = try #require(CommunitySearchArea(region: CommunitySearchFixture.region))
        let matches = try await fixture.listings(matching: "Valley", area: area, limit: 1, excluding: [])
        #expect(matches.map(\.title) == ["Valley Walk"])
    }
}
