//
//  SheetMapRevealTests.swift
//  OpenHikesTests
//
//  The hiker's own gallery brings the map in under itself rather than closing:
//  *Show on map* drops the sheet to the middle detent with the viewer still on
//  top, a tap on the photograph raises it again, and the landscape panel
//  narrows and widens with it. ``SheetPresentation`` is where that is decided,
//  through one flag — ``SheetPresentation/isShowingFullHeightScreen`` — that
//  follows the detent as well as the path. These are its rules; the gestures
//  are in `PhotoUITests` and `OrientationUITests`.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

@MainActor
@Suite("Sheet map reveal")
struct SheetMapRevealTests {
    @Test("show-on-map lowers the sheet and keeps the gallery on top")
    func revealingKeepsTheGallery() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.hike(hike), .photo(hike, UUID())]
        #expect(presentation.isShowingFullHeightScreen, "precondition: the gallery took the sheet")

        presentation.revealMapUnderFullHeightScreen()

        #expect(presentation.detent == .medium)
        #expect(presentation.path.count == 2, "the gallery is still the screen on top")
        #expect(
            presentation.isShowingFullHeightScreen == false,
            "a landscape panel would otherwise stay window-wide over the pin"
        )
    }

    @Test("covering the map again gives the gallery the whole sheet back")
    func coveringRaisesTheSheet() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.hike(hike), .photo(hike, UUID())]
        presentation.revealMapUnderFullHeightScreen()

        presentation.coverMapWithFullHeightScreen()

        #expect(presentation.detent == .large)
        #expect(presentation.isShowingFullHeightScreen)
    }

    /// The flag follows the detent, so the drag the portrait sheet already
    /// has is the same door as the tap.
    @Test("dragging the gallery down and up again moves the flag with it")
    func theFlagFollowsADrag() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .large)
        presentation.path = [.hike(hike), .photo(hike, UUID())]

        presentation.detent = .medium
        #expect(presentation.isShowingFullHeightScreen == false)

        presentation.detent = .large
        #expect(presentation.isShowingFullHeightScreen)
    }

    /// The hike was being read at `.large`, and popping a gallery that still
    /// covered everything puts it back there. One the hiker brought the map in
    /// under is popped with the map where they put it: restoring `.large`
    /// would cover the pin they had just been looking at.
    @Test("popping a gallery the map was revealed under keeps the map in view")
    func poppingAfterARevealKeepsTheHeight() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .large)
        presentation.path = [.hike(hike), .photo(hike, UUID())]
        presentation.revealMapUnderFullHeightScreen()

        presentation.path.removeLast()

        #expect(presentation.detent == .medium)
        #expect(presentation.isShowingFullHeightScreen == false)
    }

    @Test("covering the map is a no-op with no gallery on top")
    func coveringNeedsAGallery() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)
        presentation.path = [.hike(hike)]

        presentation.coverMapWithFullHeightScreen()

        #expect(presentation.detent == .medium)
    }

    /// Landscape reads the same flag to narrow the panel, and the detent goes
    /// on being written there even though no sheet shows it.
    @Test("in a side panel the reveal narrows the gallery and the cover widens it")
    func theSidePanelFollowsTheReveal() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = SheetPresentation(detent: .medium)
        presentation.layout = .sidePanel
        presentation.path = [.hike(hike), .photo(hike, UUID())]
        #expect(presentation.isShowingFullHeightScreen)

        presentation.revealMapUnderFullHeightScreen()
        #expect(presentation.isShowingFullHeightScreen == false)

        presentation.coverMapWithFullHeightScreen()
        #expect(presentation.isShowingFullHeightScreen)
    }
}
