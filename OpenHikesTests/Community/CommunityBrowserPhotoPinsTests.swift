//
//  CommunityBrowserPhotoPinsTests.swift
//  OpenHikesTests
//
//  The pins the map stands where the open preview's photographs were taken.
//
//  A third question about the same object, after *when does the map ask* and
//  *what does it get to draw* — see `CommunityBrowserRouteLinesTests`, whose
//  header makes the case for splitting them. What is different here is that
//  these pins point at **files**: they are downloaded photographs in a
//  directory the previewing screen deletes on its way out, so a pin that
//  outlived its preview would be a camera standing on the map over a file that
//  has gone.
//
//  Every assertion below is therefore about retirement as much as about
//  arrival, and the matching rules are the line's own: a preview that is not
//  the open one is ignored, and the close that clears these is matched on the
//  listing because SwiftUI tears a replaced screen down *after* its
//  replacement appears.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import Testing

@MainActor
@Suite("Community browser photo pins")
struct CommunityBrowserPhotoPinsTests {
    private static let hikeDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func region() -> MKCoordinateRegion {
        let degrees = 20_000.0 / 111_320
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            span: MKCoordinateSpan(latitudeDelta: degrees, longitudeDelta: degrees)
        )
    }

    private static func photos(_ count: Int, from: Int = 0) -> [CommunityPreviewPhoto] {
        (from..<(from + count)).map { index in
            CommunityPreviewPhoto(
                index: index,
                latitude: 47.6 + Double(index) / 100,
                longitude: 12.8 + Double(index) / 100,
                capturedAt: hikeDate.addingTimeInterval(Double(index) * 60),
                fileURL: URL(fileURLWithPath: "/tmp/community-preview/photo-\(index).jpeg")
            )
        }
    }

    /// What a tapped pin opened. A class because the closure the browser keeps
    /// escapes, and a captured `var` cannot be written from one.
    private final class OpenedPhotos {
        var indices: [Int] = []
    }

    private func settle(_ browser: CommunityBrowser) async {
        while browser.requestsInFlight > 0 {
            await Task.yield()
        }
    }

    /// A browser that has browsed, so nothing below is asserting against an
    /// object that never started.
    private func browsing() async -> CommunityBrowser {
        let transport = StubCommunityTransport()
        transport.listingsResult = .success([])
        let browser = CommunityBrowser(transport: transport, blockList: .scratch())
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        return browser
    }

    /// The loop the photographs were missing: a strip that could only count
    /// them, beside a map that now says where each one is.
    @Test("the open preview's photographs reach the map")
    func theOpenPreviewsPhotographsReachTheMap() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()

        browser.previewOpened(listing)
        browser.previewPhotosLoaded(Self.photos(3), of: listing, onOpen: nil)

        #expect(browser.photoPins.map(\.index) == [0, 1, 2])
        #expect(browser.photoPins.first?.coordinate.latitude == 47.6)
    }

    /// Nothing is on the map until a preview is up, which is what keeps this
    /// layer off a browse: a page of results has no pins, because a
    /// photograph's coordinate lives in a submission's pins asset that only
    /// the screen opening the hike ever downloads.
    @Test("a browse with no preview open draws no photo pins")
    func aBrowseAloneDrawsNoPins() async {
        let browser = await browsing()

        #expect(browser.photoPins.isEmpty)
    }

    /// The same matching rule the line follows. A fetch that lands after the
    /// hiker backed out has nowhere to go — and here it would be worse than a
    /// stray line, since it names files the screen has already deleted.
    @Test("photographs arriving after the preview closes are ignored")
    func latePhotographsAreIgnored() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()

        browser.previewOpened(listing)
        browser.previewClosed(listing)
        browser.previewPhotosLoaded(Self.photos(2), of: listing, onOpen: nil)

        #expect(browser.photoPins.isEmpty)
    }

    /// Photographs published for a hike that is not the one on screen belong
    /// to nothing the map is drawing.
    @Test("photographs for another hike are ignored")
    func photographsForAnotherHikeAreIgnored() async {
        let open = CommunityListing.stub(id: "ridge")
        let other = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let browser = await browsing()

        browser.previewOpened(open)
        browser.previewPhotosLoaded(Self.photos(2), of: other, onOpen: nil)

        #expect(browser.photoPins.isEmpty)
    }

    /// A map pin can push a second preview over an open one, and the first
    /// screen's `onDisappear` arrives *after* the second has appeared. Opening
    /// is therefore what retires the previous preview's pins — waiting for the
    /// close would leave the old hike's cameras standing on the new hike's
    /// trail, pointing at files the departing screen is deleting.
    @Test("opening another preview retires the previous one's pins")
    func openingAnotherPreviewRetiresThePins() async {
        let first = CommunityListing.stub(id: "ridge")
        let second = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let browser = await browsing()

        browser.previewOpened(first)
        browser.previewPhotosLoaded(Self.photos(3), of: first, onOpen: nil)
        browser.previewOpened(second)

        #expect(browser.photoPins.isEmpty)

        browser.previewPhotosLoaded(Self.photos(1, from: 7), of: second, onOpen: nil)
        #expect(browser.photoPins.map(\.index) == [7])
    }

    /// The map is a way into a stranger's gallery now, not only an answer to
    /// *where*: somebody who has found a photograph on the map has already
    /// decided which one they want, and sending them back to the strip to find
    /// it again is asking them to do the pin's work twice.
    @Test("tapping a pin's picture opens the gallery at that photograph")
    func tappingAPinOpensItsPhotograph() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()
        let opened = OpenedPhotos()

        browser.previewOpened(listing)
        browser.previewPhotosLoaded(Self.photos(3), of: listing) { opened.indices.append($0) }
        browser.openPreviewPhoto(2)

        #expect(opened.indices == [2])
    }

    /// The same guard the pins themselves keep: these point at files the
    /// previewing screen deletes on its way out, so a tap that lands after it
    /// has gone must not push a gallery of them onto whatever replaced it.
    @Test("a tap that lands after the preview closed opens nothing")
    func aTapAfterTheCloseOpensNothing() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()
        let opened = OpenedPhotos()

        browser.previewOpened(listing)
        browser.previewPhotosLoaded(Self.photos(3), of: listing) { opened.indices.append($0) }
        browser.previewClosed(listing)
        browser.openPreviewPhoto(1)

        #expect(opened.indices.isEmpty)
    }

    /// Retired with the pins when one preview replaces another, or a camera on
    /// the new hike's map would open a page of the old hike's gallery.
    @Test("opening another preview retires the previous one's opener")
    func openingAnotherPreviewRetiresTheOpener() async {
        let first = CommunityListing.stub(id: "ridge")
        let second = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let browser = await browsing()
        let opened = OpenedPhotos()

        browser.previewOpened(first)
        browser.previewPhotosLoaded(Self.photos(3), of: first) { opened.indices.append($0) }
        browser.previewOpened(second)
        browser.openPreviewPhoto(1)

        #expect(opened.indices.isEmpty)
    }

    /// A screen whose strip decides what stays rather than showing what is
    /// there publishes pins with nothing behind them — see
    /// ``CommunityPhotoReviewView``. Tapping one must be a no-op, not a crash.
    @Test("pins published with no opener open nothing")
    func pinsWithNoOpenerOpenNothing() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()

        browser.previewOpened(listing)
        browser.previewPhotosLoaded(Self.photos(2), of: listing, onOpen: nil)
        browser.openPreviewPhoto(0)

        #expect(browser.photoPins.map(\.index) == [0, 1])
    }

    /// Pressing *Show on map*, dismissing the callout and pressing it again is
    /// two requests — the reason the request carries a token at all.
    @Test("asking for the same pin twice is two requests")
    func askingForTheSamePinTwiceIsTwoRequests() async {
        let browser = await browsing()

        browser.selectPhotoPin(1)
        let first = browser.photoPinSelection
        browser.selectPhotoPin(1)

        #expect(first != nil)
        #expect(browser.photoPinSelection != first)
        #expect(browser.photoPinSelection?.index == 1)
    }

    /// Backing out of a preview takes its pins with it, because the files
    /// behind them go at the same moment.
    @Test("closing the preview takes its pins off the map")
    func closingThePreviewTakesThePinsOff() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()

        browser.previewOpened(listing)
        browser.previewPhotosLoaded(Self.photos(2), of: listing, onOpen: nil)
        browser.previewClosed(listing)

        #expect(browser.photoPins.isEmpty)
    }

    /// The close that arrives from a screen being torn down behind its
    /// replacement must not empty the replacement's map.
    @Test("an unmatched close leaves the open preview's pins alone")
    func anUnmatchedCloseLeavesThePinsAlone() async {
        let first = CommunityListing.stub(id: "ridge")
        let second = CommunityListing.stub(id: "summit", submissionID: "submission-2")
        let browser = await browsing()

        browser.previewOpened(first)
        browser.previewOpened(second)
        browser.previewPhotosLoaded(Self.photos(2), of: second, onOpen: nil)
        // The first screen finally disappears, after the second appeared.
        browser.previewClosed(first)

        #expect(browser.photoPins.map(\.index) == [0, 1])
    }

    /// What a reviewer striking a photograph off looks like from here: the
    /// same preview, a shorter set. The pins and the strip have to keep
    /// describing the same photographs, or the map is offering to remove one
    /// that is already gone.
    @Test("republishing a shorter set replaces the pins rather than adding to them")
    func republishingAShorterSetReplacesThePins() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()

        browser.previewOpened(listing)
        browser.previewPhotosLoaded(Self.photos(3), of: listing, onOpen: nil)
        browser.previewPhotosLoaded(Self.photos(3).filter { $0.index != 1 }, of: listing, onOpen: nil)

        #expect(browser.photoPins.map(\.index) == [0, 2])
    }

    /// Hiding the list is about the list. The preview is a screen on top of
    /// it, still showing the photographs these pins are for.
    @Test("hiding the section leaves the open preview's pins alone")
    func hidingTheSectionKeepsThePins() async {
        let listing = CommunityListing.stub(id: "ridge")
        let browser = await browsing()
        browser.previewOpened(listing)
        browser.previewPhotosLoaded(Self.photos(2), of: listing, onOpen: nil)

        browser.stopBrowsing()

        #expect(browser.photoPins.map(\.index) == [0, 1])
    }
}
