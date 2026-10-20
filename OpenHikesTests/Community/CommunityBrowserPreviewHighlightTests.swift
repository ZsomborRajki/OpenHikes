//
//  CommunityBrowserPreviewHighlightTests.swift
//  OpenHikesTests
//
//  The dot the map stands where an open preview's elevation chart is pointing.
//
//  A fourth question about the same object, after the lines and the photo pins
//  — see `CommunityBrowserRouteLinesTests` for why each gets a file of its own.
//  A hike of the hiker's own has always moved a dot along its line as its
//  chart is scrubbed; a stranger's chart moved nothing on the map at all, over
//  a map drawing that very route at full strength.
//
//  What is pinned is the dot's lifetime, which is the previewed line's: it
//  stands only where there is a chart position *and* a line to stand on, it
//  follows the chart, and it goes with the line — matched on the listing,
//  because SwiftUI tears a replaced screen down after its replacement appears.
//  And it is pinned as moving nothing else this browser publishes, because a
//  finger moves it at display rate.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Community browser preview highlight")
struct CommunityBrowserPreviewHighlightTests {
    /// The previewed hike's route — the line the dot stands on. Its points are
    /// never read back: what matters is that there is a line.
    private static let route = [
        RouteCoordinate(latitude: 47.63, longitude: 12.86),
        RouteCoordinate(latitude: 47.64, longitude: 12.87),
        RouteCoordinate(latitude: 47.65, longitude: 12.88),
    ]
    /// Two points along it, as the chart would hand them over.
    private static let partWay = CLLocationCoordinate2D(latitude: 47.64, longitude: 12.87)
    private static let further = CLLocationCoordinate2D(latitude: 47.645, longitude: 12.875)

    /// A browser with `listing`'s preview open and its route loaded — the
    /// state the chart can be scrubbed in at all, since it is drawn from that
    /// route. No transport: nothing here asks anybody anything.
    private func previewing(_ listing: CommunityListing) -> CommunityBrowser {
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        browser.previewOpened(listing)
        browser.previewLoaded(Self.route, of: listing)
        return browser
    }

    /// The loop that was missing: a finger on a stranger's chart reaches the
    /// map, as one on a hike of the hiker's own always has.
    @Test("the open preview's chart position reaches the map")
    func theChartPositionReachesTheMap() {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)

        browser.previewScrubbed(to: Self.partWay, of: listing)

        #expect(browser.previewHighlight?.listing.id == "ridge")
        #expect(browser.previewHighlight?.coordinate.latitude == Self.partWay.latitude)
        #expect(browser.previewHighlight?.coordinate.longitude == Self.partWay.longitude)
    }

    /// A drag is a run of positions, and the dot is wherever the last one put
    /// it — including after the finger lifts, which is where the chart leaves
    /// its own marker too.
    @Test("the dot follows the chart")
    func theDotFollowsTheChart() {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)

        browser.previewScrubbed(to: Self.partWay, of: listing)
        browser.previewScrubbed(to: Self.further, of: listing)

        #expect(browser.previewHighlight?.coordinate.latitude == Self.further.latitude)
        #expect(browser.previewHighlight?.coordinate.longitude == Self.further.longitude)
    }

    /// A chart position is a point on the drawn route, so with no line drawn
    /// there is nothing for the dot to stand on — and once the line lands,
    /// the dot is on it, whichever of the two arrived first.
    @Test("the dot waits for the line it stands on")
    func theDotWaitsForItsLine() {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = CommunityBrowser(transport: nil, blockList: .scratch())
        browser.previewOpened(listing)

        browser.previewScrubbed(to: Self.partWay, of: listing)
        #expect(browser.previewHighlight == nil, "no line yet, so no dot")

        browser.previewLoaded(Self.route, of: listing)
        #expect(browser.previewHighlight?.listing.id == "ridge")
    }

    /// The matching rule every other call from the preview follows. A chart
    /// on a screen that is not the open one belongs to nothing the map is
    /// drawing.
    @Test("a scrub for another hike is ignored")
    func aScrubForAnotherHikeIsIgnored() {
        let open = CommunityListing.stub(id: "ridge")
        let other = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let browser = previewing(open)

        browser.previewScrubbed(to: Self.partWay, of: other)

        #expect(browser.previewHighlight == nil)
    }

    /// Backing out of a preview takes its line off the map, and a dot left
    /// behind would be a dot on nothing.
    @Test("closing the preview takes the dot off the map")
    func closingThePreviewTakesTheDotOff() {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)
        browser.previewScrubbed(to: Self.partWay, of: listing)

        browser.previewClosed(listing)

        #expect(browser.previewHighlight == nil)
    }

    /// Nor does a chart position arriving after the close bring one back — a
    /// scrub landing as the screen goes is the ordinary case, not an exotic
    /// one, since the finger can still be on the chart as it slides away.
    @Test("a scrub after the preview closed is ignored")
    func aScrubAfterTheCloseIsIgnored() {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)

        browser.previewClosed(listing)
        browser.previewScrubbed(to: Self.partWay, of: listing)

        #expect(browser.previewHighlight == nil)
    }

    /// A map pin can push a second preview over an open one, and the first
    /// screen's close arrives *after* the second has appeared. Opening is what
    /// retires the first hike's dot — waiting for its close would leave it on
    /// the map, and the second chart's first touch would carry it over.
    @Test("opening another preview retires the previous one's dot")
    func openingAnotherPreviewRetiresTheDot() {
        let first = CommunityListing.stub(id: "ridge")
        let second = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let browser = previewing(first)
        browser.previewScrubbed(to: Self.partWay, of: first)

        browser.previewOpened(second)
        #expect(browser.previewHighlight == nil)

        browser.previewLoaded(Self.route, of: second)
        #expect(browser.previewHighlight == nil, "the new chart has not said where it is pointing yet")

        browser.previewScrubbed(to: Self.further, of: second)
        #expect(browser.previewHighlight?.listing.id == "summit")
    }

    /// The close that arrives from a screen being torn down behind its
    /// replacement must not take the replacement's dot with it.
    @Test("an unmatched close leaves the open preview's dot alone")
    func anUnmatchedCloseLeavesTheDotAlone() {
        let first = CommunityListing.stub(id: "ridge")
        let second = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let browser = previewing(first)
        browser.previewOpened(second)
        browser.previewLoaded(Self.route, of: second)
        browser.previewScrubbed(to: Self.partWay, of: second)

        // The first screen finally disappears, after the second appeared.
        browser.previewClosed(first)

        #expect(browser.previewHighlight?.listing.id == "summit")
    }

    /// The dot moves at drag frequency, so it must wake the map's dot and
    /// nothing else this browser publishes — least of all the lines, which the
    /// map rebuilds wholesale when they change, or the rows the sheet draws.
    ///
    /// Settling between the two moves on purpose: drag events arrive in
    /// separate runloop turns, so this counts them as the map would see them.
    @Test("a scrub wakes the dot and nothing else")
    func aScrubWakesOnlyTheDot() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = previewing(listing)
        let dot = ObservationCounter { _ = browser.previewHighlight }
        let lines = ObservationCounter { _ = browser.routeLines }
        let pins = ObservationCounter { _ = browser.photoPins }
        let rows = ObservationCounter { _ = browser.nearbyListings }
        let state = ObservationCounter { _ = browser.state }
        await dot.settle()

        browser.previewScrubbed(to: Self.partWay, of: listing)
        await dot.settle()
        browser.previewScrubbed(to: Self.further, of: listing)
        await dot.settle()

        // The precondition the zeros below are worth something under: both
        // writes happened, and both reached the dot.
        #expect(browser.previewHighlight?.coordinate.latitude == Self.further.latitude)
        #expect(dot.count == 2)
        #expect(lines.count == 0)
        #expect(pins.count == 0)
        #expect(rows.count == 0)
        #expect(state.count == 0)
    }
}
