//
//  CommunityBrowserRouteLinesTests.swift
//  OpenHikesTests
//
//  The lines the map draws for other people's hikes: where they come from,
//  what happens to them when the list they belong to changes, and how the one
//  the hiker is actually looking at is different.
//
//  Its own file rather than more of `CommunityBrowserTests.swift` for the
//  reason the blocking suite has one: this is a second question about the
//  same object — not *when does the map ask* but *what does it get to draw* —
//  and one suite answering both is a file nobody can find anything in.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// Where the shared hikes go, as opposed to where they start.
@MainActor
@Suite("Community browser route lines")
struct CommunityBrowserRouteLinesTests {
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

    /// A short line, which is all any of these assertions needs: the thinning
    /// and the encoding are `CommunityRouteOutlineTests`' business.
    private static func outline(offset: Double = 0) -> [RouteCoordinate] {
        [
            RouteCoordinate(latitude: 47.63 + offset, longitude: 12.86),
            RouteCoordinate(latitude: 47.64 + offset, longitude: 12.87),
            RouteCoordinate(latitude: 47.65 + offset, longitude: 12.88),
        ]
    }

    private func settle(_ browser: CommunityBrowser) async {
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    /// A browser holding a page of published hikes and their shapes.
    private func loaded(
        _ listings: [CommunityListing],
        outlines: [String: [RouteCoordinate]],
        blockList: CommunityBlockList = .scratch()
    ) async -> (browser: CommunityBrowser, transport: StubCommunityTransport) {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success(listings)
        transport.outlinesResult = .success(outlines)
        let browser = CommunityBrowser(transport: transport, blockList: blockList)
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        return (browser, transport)
    }

    // MARK: - Getting them

    /// The loop the feature was missing: a region goes in, and what comes back
    /// is trails rather than points.
    @Test("a nearby answer brings back the shape of each hike")
    func anAnswerBringsBackShapes() async {
        let (browser, _) = await loaded(
            [.stub(id: "ridge"), .stub(id: "summit", submissionID: "submission-2")],
            outlines: ["ridge": Self.outline(), "summit": Self.outline(offset: 0.1)]
        )

        #expect(browser.routeLines.map(\.id) == ["ridge", "summit"])
        #expect(browser.routeLines.allSatisfy { !$0.isPreviewed })
        #expect(browser.routeLines.first?.coordinates.count == 3)
    }

    /// One request for the page, which is the whole affordability argument:
    /// a fetch per row would be twenty-five round trips for a list somebody
    /// may scroll past.
    @Test("the whole page's shapes cost one request")
    func onePageIsOneRequest() async {
        let (_, transport) = await loaded(
            [
                .stub(id: "ridge"),
                .stub(id: "summit", submissionID: "submission-2"),
                .stub(id: "tarn", submissionID: "submission-3"),
            ],
            outlines: [:]
        )

        #expect(transport.recording.outlineRequests.count == 1)
        #expect(transport.recording.outlineRequests.first?.count == 3)
    }

    /// Every hike published before the field existed is in this state, so it
    /// is the ordinary case rather than the edge one: the row and the pin
    /// stand, and there is simply no line.
    @Test("a hike with no shape keeps its pin and draws no line")
    func amissingShapeIsNotAFailure() async {
        let (browser, _) = await loaded(
            [.stub(id: "ridge"), .stub(id: "summit", submissionID: "submission-2")],
            outlines: ["ridge": Self.outline()]
        )

        #expect(browser.nearbyListings.count == 2, "both are still rows and pins")
        #expect(browser.routeLines.map(\.id) == ["ridge"])
    }

    /// The lines are a second request and must not be able to cost the first
    /// one anything: rows and pins that arrived are kept whatever happens to
    /// the geometry behind them.
    @Test("a failed shape request costs the lines and nothing else")
    func aFailedShapeRequestKeepsTheRows() async {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([.stub(id: "ridge")])
        transport.outlinesResult = .failure(.unreachable)
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        #expect(browser.nearbyListings.map(\.id) == ["ridge"])
        #expect(browser.routeLines.isEmpty)
        #expect(browser.state == .loaded, "the nearby answer succeeded")
    }

    // MARK: - Losing them

    /// Hiding the section takes the lines with the pins. A trail left drawn
    /// over a map whose list no longer mentions it is the feature's own
    /// litter.
    @Test("hiding the section takes the lines with it")
    func hidingTheSectionClearsTheLines() async {
        let (browser, _) = await loaded(
            [.stub(id: "ridge")],
            outlines: ["ridge": Self.outline()]
        )
        #expect(!browser.routeLines.isEmpty)

        browser.stopBrowsing()

        #expect(browser.routeLines.isEmpty)
    }

    /// The same filter the rows go through, which is what makes one block
    /// reach both without either being remembered separately.
    @Test("a blocked author's line goes when their row does")
    func blockingTakesTheLineToo() async {
        let blockList = CommunityBlockList.scratch()
        let (browser, _) = await loaded(
            [.stub(id: "ridge", authorID: "author-1")],
            outlines: ["ridge": Self.outline()],
            blockList: blockList
        )
        #expect(browser.routeLines.map(\.id) == ["ridge"])

        blockList.block(.stub(id: "ridge", authorID: "author-1"))

        #expect(browser.routeLines.isEmpty)
    }

    // MARK: - The open preview

    /// What replaces the sketch the preview used to draw: the hike the hiker
    /// is deciding about, on the map, at full fidelity.
    @Test("the open preview's own route replaces its outline")
    func aPreviewDrawsItsRealRoute() async {
        let listing = CommunityListing.stub(id: "ridge")
        let (browser, _) = await loaded(
            [listing],
            outlines: ["ridge": Self.outline()]
        )

        browser.previewOpened(listing)
        #expect(browser.routeLines.first?.coordinates.count == 3, "the outline is still all there is")

        let full = (0..<50).map { index in
            RouteCoordinate(latitude: 47.63 + Double(index) * 0.001, longitude: 12.86)
        }
        browser.previewLoaded(full, of: listing)

        #expect(browser.routeLines.count == 1, "one trail, not two versions of it")
        let line = browser.routeLines.first
        #expect(line?.coordinates.count == 50)
        #expect(line?.isPreviewed == true)
    }

    /// A hike found by typing its name is nowhere in the nearby answer, and is
    /// exactly the case where the preview has nothing else to show a route
    /// on.
    @Test("a preview outside the nearby answer is still drawn")
    func aPreviewOutsideTheAnswerIsDrawn() async {
        let (browser, _) = await loaded([.stub(id: "ridge")], outlines: [:])
        let elsewhere = CommunityListing.stub(id: "faraway", submissionID: "submission-9")

        browser.previewOpened(elsewhere)
        browser.previewLoaded(Self.outline(offset: 5), of: elsewhere)

        #expect(browser.routeLines.map(\.id) == ["faraway"])
    }

    /// Backing out takes the line away.
    @Test("closing the preview takes its route off the map")
    func closingThePreviewClearsIt() async {
        let listing = CommunityListing.stub(id: "ridge")
        let (browser, _) = await loaded([listing], outlines: [:])

        browser.previewOpened(listing)
        browser.previewLoaded(Self.outline(), of: listing)
        #expect(browser.routeLines.count == 1)

        browser.previewClosed(listing)

        #expect(browser.routeLines.isEmpty)
    }

    /// SwiftUI tears a replaced screen down *after* its replacement appears,
    /// so an unmatched close would blank the new preview's line on the way
    /// into it.
    @Test("a superseded preview's close does not clear the new one")
    func asupersededCloseIsIgnored() async {
        let first = CommunityListing.stub(id: "ridge")
        let second = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let (browser, _) = await loaded([], outlines: [:])

        browser.previewOpened(first)
        browser.previewOpened(second)
        browser.previewLoaded(Self.outline(), of: second)
        browser.previewClosed(first)

        #expect(browser.routeLines.map(\.id) == ["summit"])
    }

    /// A fetch that lands after the hiker backed out has nowhere to go, and
    /// must not put a line on a map with no screen behind it.
    @Test("a route arriving after the preview closes is ignored")
    func aLateRouteIsIgnored() async {
        let listing = CommunityListing.stub(id: "ridge")
        let (browser, _) = await loaded([], outlines: [:])

        browser.previewOpened(listing)
        browser.previewClosed(listing)
        browser.previewLoaded(Self.outline(), of: listing)

        #expect(browser.routeLines.isEmpty)
    }

    /// Hiding the section is about the list, and the preview is a screen on
    /// top of it. Blanking the trail it is showing would be the one place in
    /// the app still answering a question nobody asked.
    @Test("hiding the section leaves the open preview's line alone")
    func hidingTheSectionKeepsThePreview() async {
        let listing = CommunityListing.stub(id: "ridge")
        let (browser, _) = await loaded(
            [listing],
            outlines: ["ridge": Self.outline()]
        )
        browser.previewOpened(listing)
        browser.previewLoaded(Self.outline(), of: listing)

        browser.stopBrowsing()

        #expect(browser.routeLines.map(\.id) == ["ridge"])
        #expect(browser.routeLines.first?.isPreviewed == true)
    }
}
