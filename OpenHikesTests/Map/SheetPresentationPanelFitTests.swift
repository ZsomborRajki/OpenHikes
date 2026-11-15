//
//  SheetPresentationPanelFitTests.swift
//  OpenHikesTests
//
//  The side panel stands as tall as the screen on top of the sheet's stack,
//  and ``SheetPresentation`` is what knows which screen that is. These are
//  the two things it tells ``SidePanelFit``: every change to the path, and
//  the panel being taken down. What the fit does with them is
//  `SidePanelFitTests`.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

@MainActor
@Suite("Sheet presentation panel fit")
struct SheetPresentationPanelFitTests {
    /// A presentation in a panel with height to spare, whose root has asked
    /// for 400 points.
    private func presentation() -> SheetPresentation {
        let presentation = SheetPresentation(detent: .medium)
        presentation.layout = .sidePanel
        let fit = presentation.panelFit
        fit.fitsContent = true
        fit.report(bars: 0, atDepth: 0)
        fit.report(content: 400, from: fit.nameScreen(), atDepth: 0)
        return presentation
    }

    @Test("the panel follows the screen on top of the path")
    func followsTheTopOfThePath() {
        let presentation = presentation()
        let fit = presentation.panelFit

        presentation.path = [.totals]
        fit.report(bars: 54, atDepth: 1)
        fit.report(content: 600, from: fit.nameScreen(), atDepth: 1)
        #expect(fit.height == 654)

        presentation.path = []
        #expect(fit.height == 400, "the root never stopped asking for this")
    }

    /// Pushed and popped one screen at a time, the screens under the top one
    /// stay what they were. A jump assigns the whole path, and every screen
    /// it takes away is gone, however deep.
    @Test("a jump from deeper in the stack holds the panel for the screen it opens")
    func aJumpForgetsTheScreensItReplaces() {
        let presentation = presentation()
        let fit = presentation.panelFit
        presentation.path = [.totals]
        fit.report(bars: 54, atDepth: 1)
        fit.report(content: 900, from: fit.nameScreen(), atDepth: 1)
        presentation.path.append(.trailDraft)
        fit.report(bars: 54, atDepth: 2)
        fit.report(content: 300, from: fit.nameScreen(), atDepth: 2)
        #expect(fit.height == 354)

        presentation.path.removeLast()
        #expect(fit.height == 954, "a pop keeps the screen underneath")

        presentation.path.append(.trailDraft)
        fit.report(bars: 54, atDepth: 2)
        fit.report(content: 300, from: fit.nameScreen(), atDepth: 2)
        presentation.path = [.recording]

        #expect(fit.height == 354, "held, and not the 954 the totals under the maker asked for")
    }

    /// A photograph is one picture: beside the map it has the column's whole
    /// height, whatever the hike under it asked for.
    @Test("a photo viewer on top takes the window's height")
    func aPhotoViewerTakesTheWindowsHeight() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let presentation = presentation()
        let fit = presentation.panelFit
        presentation.path = [.hike(hike)]
        fit.report(bars: 54, atDepth: 1)
        fit.report(content: 600, from: fit.nameScreen(), atDepth: 1)

        presentation.path.append(.photo(hike, UUID()))
        #expect(fit.height == nil)

        presentation.path.removeLast()
        #expect(fit.height == 654)
    }

    /// The screens are built again in the next panel, and say what they need
    /// as they are laid out.
    @Test("the panel taken down keeps nothing of what its screens asked")
    func theSheetForgetsThePanel() {
        let presentation = presentation()
        let fit = presentation.panelFit

        presentation.layout = .bottomSheet
        #expect(fit.height == nil)

        presentation.layout = .sidePanel
        fit.report(bars: 0, atDepth: 0)
        #expect(fit.height == nil, "the root's old 400 points were not kept")
    }
}
