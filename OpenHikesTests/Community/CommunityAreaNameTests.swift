//
//  CommunityAreaNameTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import Testing

/// What the shared-hikes section is headed with, and when.
///
/// The header used to say *Nearby*, which named the query and never the
/// answer. A hiker who had panned, or who opened the app somewhere they were
/// not yesterday, had no way to tell which "here" the rows were from — and a
/// name that lagged behind the list would be worse than none, because it would
/// be a place the rows are not about.
@MainActor
@Suite("Community area name")
struct CommunityAreaNameTests {
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
        // The name is asked for beside the request rather than inside it, so
        // one more turn is what lets that task land.
        await Task.yield()
    }

    @Test("the searched area is named once something has answered")
    func committingNamesTheArea() async {
        let names = StubAreaNames(answer: "Esztergom")
        let browser = CommunityBrowser(
            transport: StubCommunityTransport(),
            blockList: .scratch(),
            areaNames: names
        )
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        #expect(browser.areaName == "Esztergom")
        #expect(names.asked.count == 1)
        #expect(names.asked.first?.latitude == 47.63)
    }

    /// The name has to describe the rows. A geocode that has not come back is
    /// no name at all rather than the previous area's.
    @Test("searching somewhere else drops the old name immediately")
    func aNewAreaDropsTheOldName() async {
        let names = StubAreaNames(answer: "Esztergom")
        let browser = CommunityBrowser(
            transport: StubCommunityTransport(),
            blockList: .scratch(),
            areaNames: names
        )
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)
        #expect(browser.areaName == "Esztergom")

        names.answer = nil
        browser.regionDidSettle(Self.region(latitude: 48.03))
        browser.searchVisibleArea()
        #expect(browser.areaName == nil)
        await settle(browser)

        #expect(browser.areaName == nil)
        #expect(names.asked.count == 2)
        #expect(names.asked.last?.latitude == 48.03)
    }

    /// A pan the hiker never confirms changes nothing the header says,
    /// because it changes nothing the list shows.
    @Test("an untaken offer does not rename the list")
    func anOfferDoesNotRename() async {
        let names = StubAreaNames(answer: "Esztergom")
        let browser = CommunityBrowser(
            transport: StubCommunityTransport(),
            blockList: .scratch(),
            areaNames: names
        )
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        browser.regionDidSettle(Self.region(latitude: 48.03))
        await settle(browser)

        #expect(browser.areaName == "Esztergom")
        #expect(names.asked.count == 1)
    }

    /// Hiding the section takes the heading with it, so asking for it again
    /// does not open on a place from another session.
    @Test("hiding the section forgets the name")
    func hidingForgetsTheName() async {
        let names = StubAreaNames(answer: "Esztergom")
        let browser = CommunityBrowser(
            transport: StubCommunityTransport(),
            blockList: .scratch(),
            areaNames: names
        )
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        browser.stopBrowsing()
        #expect(browser.areaName == nil)
    }

    /// A launch that must not reach CloudKit must not reach MapKit's geocoder
    /// either — see ``OpenHikesModel/makeCommunityBrowser(transport:blocks:)``.
    @Test("a browser with no namer heads its list with nothing")
    func anAbsentNamerIsInert() async {
        let browser = CommunityBrowser(
            transport: StubCommunityTransport(),
            blockList: .scratch()
        )
        browser.regionDidSettle(Self.region())
        browser.startBrowsing()
        await settle(browser)

        #expect(browser.areaName == nil)
    }
}
