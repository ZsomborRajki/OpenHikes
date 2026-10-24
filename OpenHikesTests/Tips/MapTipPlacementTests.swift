//
//  MapTipPlacementTests.swift
//  OpenHikesTests
//
//  Where the main screen's tip is drawn on the map, decided from what the map
//  can see — see ``MapTipPlacement``. The card it draws is `TipUIView` and
//  TipKit's, and only a running app shows one; the decision is this.
//

@testable import OpenHikes
import Testing

@Suite("Map tip placement")
struct MapTipPlacementTests {
    @Test(
        "the tips about making a hike go over the pill, for a hiker they are for",
        arguments: [RecordHikeTip.tipID, MakeTrailTip.tipID]
    )
    func creationTipsGoOverThePill(tipID: String) {
        let placement = MapTipPlacement(
            tipID: tipID,
            creationTipsAreWanted: true,
            pillIsOffered: true,
            areaSearchIsIdle: false
        )
        #expect(placement == .abovePill(tipID: tipID))
    }

    /// The owner's rule for an existing hiker: the two are about buttons they
    /// have already found. A list that has not loaded yet is not known to be
    /// empty either, and is answered the same way — see
    /// ``CreationTipsAudience``, whose suite walks who they are for.
    @Test("a hiker the tips about making a hike are not for is never shown them")
    func creationTipsWaitForAnEmptyLibrary() {
        let placement = MapTipPlacement(
            tipID: RecordHikeTip.tipID,
            creationTipsAreWanted: false,
            pillIsOffered: true,
            areaSearchIsIdle: true
        )
        #expect(placement == nil)
    }

    /// A screen pushed over the map puts the camera pill where these were,
    /// and a card about the maker's buttons standing over the camera's would
    /// be about buttons that are not there.
    @Test("the tips about making a hike leave with the pill")
    func creationTipsNeedThePill() {
        let placement = MapTipPlacement(
            tipID: MakeTrailTip.tipID,
            creationTipsAreWanted: true,
            pillIsOffered: false,
            areaSearchIsIdle: true
        )
        #expect(placement == nil)
    }

    @Test("one tip about the pill giving way to the other is a different card")
    func eachCreationTipIsItsOwnCard() {
        #expect(MapTipPlacement.abovePill(tipID: RecordHikeTip.tipID) != .abovePill(tipID: MakeTrailTip.tipID))
    }

    @Test("Search this area's tip goes under the pill once it is there and idle")
    func searchTipGoesUnderThePill() {
        let idle = MapTipPlacement(
            tipID: SearchThisAreaTip.tipID,
            creationTipsAreWanted: false,
            pillIsOffered: true,
            areaSearchIsIdle: true
        )
        #expect(idle == .underAreaSearch)
    }

    /// Off the map with the *Community* tab, or spinning over the first
    /// search: either way there is no answer yet for the tip to explain.
    @Test("Search this area's tip waits for the pill and its first answer")
    func searchTipWaitsForTheAnswer() {
        let busy = MapTipPlacement(
            tipID: SearchThisAreaTip.tipID,
            creationTipsAreWanted: false,
            pillIsOffered: true,
            areaSearchIsIdle: false
        )
        #expect(busy == nil)
    }

    /// The pill stays on the map with its tab whatever is pushed over the
    /// sheet, but a pushed screen may show a tip of its own — the recording
    /// screen's, after a Record tapped from the *Community* tab — and a
    /// screen never shows two at once.
    @Test("Search this area's tip leaves while a screen is pushed")
    func searchTipWaitsWhileAScreenIsPushed() {
        let pushed = MapTipPlacement(
            tipID: SearchThisAreaTip.tipID,
            creationTipsAreWanted: false,
            pillIsOffered: false,
            areaSearchIsIdle: true
        )
        #expect(pushed == nil)
    }

    /// The *Community* tab's tip is the sheet's to draw, the recording
    /// screen's two are another group's, and a group with nothing due has
    /// nothing for the map either.
    @Test(
        "no other tip is the map's",
        arguments: [CommunityTabTip.tipID, AddPlaceTip.tipID, PlacesNearbyTip.tipID, nil] as [String?]
    )
    func otherTipsAreNotTheMaps(tipID: String?) {
        let placement = MapTipPlacement(
            tipID: tipID,
            creationTipsAreWanted: true,
            pillIsOffered: true,
            areaSearchIsIdle: true
        )
        #expect(placement == nil)
    }
}
