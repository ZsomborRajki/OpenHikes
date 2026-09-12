import Foundation
import MapKit
@testable import OpenHikes
import Testing

@MainActor
@Suite("Community title search debounce", .timeLimit(.minutes(1)))
struct CommunityTitleSearchTests {
    private let transport = StubCommunityTransport()
    private let clock = CommunitySearchClock()
    private let keystrokeInterval: Duration = .milliseconds(100)
    private let quietPeriod: Duration = .milliseconds(300)

    private func edit(_ query: String, in browser: CommunityBrowser) -> Task<Void, Never> {
        browser.prepareTitleSearch(matching: query)
        return Task { await browser.searchAfterQuietPeriod(matching: query, clock: clock) }
    }

    private func waitForClock() async {
        await settleDelegateHop(until: "the quiet-period wait is registered") { clock.pendingWaits == 1 }
    }

    private func settle(_ browser: CommunityBrowser) async {
        await settleDelegateHop(until: "all community requests finish") { browser.requestsInFlight == 0 }
    }

    @Test("a burst asks once, only after the last edit's quiet period")
    func burst() async {
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        var pending: Task<Void, Never>?
        for query in ["P", "Pi", "Pil", "Pili", "Pilis"] {
            pending?.cancel()
            await pending?.value
            pending = edit(query, in: browser)
            await waitForClock()
            clock.advance(by: keystrokeInterval)
            #expect(transport.recording.titleQueries.isEmpty)
        }
        clock.advance(by: quietPeriod - keystrokeInterval)
        await pending?.value
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis"])
    }

    @Test("clearing immediately drops matches and cancels pending work")
    func clear() async {
        transport.listingsResult = .success([.stub()])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "existing")
        await settle(browser)
        #expect(!browser.matchingListings.isEmpty)
        let pending = edit("Pilis", in: browser)
        await waitForClock()
        browser.prepareTitleSearch(matching: " \n ")
        #expect(browser.matchingListings.isEmpty)
        pending.cancel()
        await pending.value
        await browser.searchAfterQuietPeriod(matching: "", clock: clock)
        clock.advance(by: quietPeriod)
        #expect(clock.pendingWaits == 0)
        #expect(transport.recording.titleQueries == ["existing"])
    }

    @Test("Return flushes once and equivalent edits reuse the answer")
    func submitAndDeduplicate() async {
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        let pending = edit("Pilis", in: browser)
        await waitForClock()
        browser.search(matching: "Pilis")
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis"])
        clock.advance(by: quietPeriod)
        await pending.value
        await browser.searchAfterQuietPeriod(matching: "  PILIS\n", clock: clock)
        browser.search(matching: "pilis")
        await settle(browser)
        #expect(clock.pendingWaits == 0)
        #expect(transport.recording.titleQueries == ["Pilis"])
    }

    /// The deduplication that makes Return cheap must not also make a failed
    /// search unrepeatable: nothing on screen reports the failure, so pressing
    /// Return again is the whole of the retry a hiker has.
    @Test("a failed title search can be submitted again")
    func retryAfterFailure() async {
        transport.listingsResult = .failure(.unreachable)
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "Pilis")
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis"])
        #expect(browser.matchingListings.isEmpty)

        transport.listingsResult = .success([.stub(id: "pilis")])
        browser.search(matching: "Pilis")
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis", "Pilis"])
        #expect(browser.matchingListings.map(\.id) == ["pilis"])

        // And the answer that arrived is reused, so the retry has not simply
        // turned the guard off.
        browser.search(matching: "  PILIS ")
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis", "Pilis"])
    }

    @Test("a disappearing field cancels its wait without a request")
    func disappearance() async {
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        let pending = edit("Pilis", in: browser)
        await waitForClock()
        pending.cancel()
        await pending.value
        clock.advance(by: quietPeriod)
        #expect(clock.pendingWaits == 0)
        #expect(transport.recording.titleQueries.isEmpty)
        let replacement = edit("Pilis", in: browser)
        await waitForClock()
        clock.advance(by: quietPeriod)
        await replacement.value
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis"])
    }

    @Test("nearby requests run while a title is waiting")
    func nearbyIsIndependent() async {
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        let pending = edit("Pilis", in: browser)
        await waitForClock()
        browser.regionDidSettle(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47, longitude: 12),
            latitudinalMeters: 20_000,
            longitudinalMeters: 20_000
        ))
        browser.startBrowsing()
        await settle(browser)
        #expect(transport.recording.nearbyRequests.count == 1)
        #expect(transport.recording.titleQueries.isEmpty)
        clock.advance(by: quietPeriod)
        await pending.value
        await settle(browser)
        #expect(transport.recording.titleQueries == ["Pilis"])
    }

    @Test("an edit invalidates a response before its quiet period", arguments: ["new", ""])
    func invalidateImmediately(query: String) async {
        let gate = TitleResponseGate()
        transport.beforeListingsReturn = { await gate.waitForFirstRequest() }
        transport.listingsResult = .success([.stub(id: "old")])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "old")
        await settleDelegateHop(until: "the old query reaches the transport") {
            transport.recording.titleQueries == ["old"]
        }
        browser.prepareTitleSearch(matching: query)
        await gate.open()
        await settle(browser)
        #expect(browser.matchingListings.isEmpty)
        #expect(transport.recording.titleQueries == ["old"])
    }

    @Test("an old response arriving last cannot replace the newer answer")
    func staleResponse() async {
        let gate = TitleResponseGate()
        transport.beforeListingsReturn = { await gate.waitForFirstRequest() }
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.search(matching: "old")
        await settleDelegateHop(until: "the old query reaches the transport") {
            transport.recording.titleQueries == ["old"]
        }
        let pending = edit("new", in: browser)
        await waitForClock()
        transport.listingsResult = .success([.stub(id: "new")])
        clock.advance(by: quietPeriod)
        await pending.value
        await settleDelegateHop(until: "the new answer is published") {
            browser.matchingListings.map(\.id) == ["new"]
        }
        transport.listingsResult = .success([.stub(id: "old")])
        await gate.open()
        await settle(browser)
        #expect(transport.recording.titleQueries == ["old", "new"])
        #expect(browser.matchingListings.map(\.id) == ["new"])
    }
}

private actor TitleResponseGate {
    private var requests = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func waitForFirstRequest() async {
        requests += 1
        guard requests == 1, !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
