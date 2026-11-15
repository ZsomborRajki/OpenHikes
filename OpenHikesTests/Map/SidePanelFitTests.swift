//
//  SidePanelFitTests.swift
//  OpenHikesTests
//
//  How tall the side panel stands where its window has height to spare — see
//  ``SidePanelFit``. The figures here stand for what the screens measure: the
//  bars the navigation stack draws around one, and what it needs inside them.
//  Where they come from is `SidePanelFitReport.swift`, which only a window can
//  exercise; what is done with them is these rules.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Side panel fit")
struct SidePanelFitTests {
    /// A panel in a window with height to spare, whose root screen has asked
    /// for `root` points inside no bars.
    private func fit(root: CGFloat = 400) -> SidePanelFit {
        let fit = SidePanelFit()
        fit.fitsContent = true
        fit.report(bars: 0, atDepth: 0)
        fit.report(content: root, from: fit.nameScreen(), atDepth: 0)
        return fit
    }

    @Test("the panel stands as tall as its screen and the bars around it")
    func standsAsTallAsTheScreenOnTop() {
        let fit = fit()
        fit.show(depth: 1, fillingPanel: false)

        fit.report(bars: 54, atDepth: 1)
        fit.report(content: 390.2, from: fit.nameScreen(), atDepth: 1)

        #expect(fit.height == 445, "whole points, rounded up, so a row is never a hair short")
    }

    @Test("a window with no height to spare keeps the panel the window's height")
    func aCompactHeightKeepsTheWindowsHeight() {
        let fit = SidePanelFit()

        fit.report(bars: 0, atDepth: 0)
        fit.report(content: 400, from: fit.nameScreen(), atDepth: 0)

        #expect(fit.height == nil)
    }

    /// An iPhone Duo on its side is the same panel opened or closed, and its
    /// screens say what they need once.
    @Test("what the screens asked is kept across a change of height class")
    func whatWasAskedSurvivesTheHeightClass() {
        let fit = fit()
        #expect(fit.height == 400)

        fit.fitsContent = false
        #expect(fit.height == nil)

        fit.fitsContent = true
        #expect(fit.height == 400)
    }

    @Test("a screen is fitted only once its bars and its contents are both known")
    func waitsForBothHalves() {
        let fit = SidePanelFit()
        fit.fitsContent = true

        fit.report(content: 400, from: fit.nameScreen(), atDepth: 0)
        #expect(fit.height == nil)

        fit.report(bars: 0, atDepth: 0)
        #expect(fit.height == 400)
    }

    @Test("the panel is never shorter than its minimum")
    func neverShorterThanItsMinimum() {
        let fit = fit(root: 60)

        #expect(fit.height == MapSidePanelLayout.minimumHeight)
    }

    /// Opening to the whole window for the frame between the push and the new
    /// screen's first layout is what this prevents.
    @Test("a push keeps the panel's height until the new screen is laid out")
    func holdsItsHeightUntilThePushedScreenAsks() {
        let fit = fit()

        fit.show(depth: 1, fillingPanel: false)
        #expect(fit.height == 400)

        fit.report(bars: 54, atDepth: 1)
        #expect(fit.height == 400, "half an answer is none")

        fit.report(content: 700, from: fit.nameScreen(), atDepth: 1)
        #expect(fit.height == 754)
    }

    /// A covered screen does not change, so it will not ask again.
    @Test("a pop returns to what the screen underneath asked for")
    func aPopReturnsToTheScreenUnderneath() {
        let fit = fit()
        fit.show(depth: 1, fillingPanel: false)
        fit.report(bars: 54, atDepth: 1)
        fit.report(content: 700, from: fit.nameScreen(), atDepth: 1)

        fit.show(depth: 0, fillingPanel: false)

        #expect(fit.height == 400)
    }

    @Test("what a popped screen asked for is not the next screen's")
    func forgetsWhatAPoppedScreenAsked() {
        let fit = fit()
        fit.show(depth: 1, fillingPanel: false)
        fit.report(bars: 54, atDepth: 1)
        fit.report(content: 700, from: fit.nameScreen(), atDepth: 1)
        fit.show(depth: 0, fillingPanel: false)

        fit.show(depth: 1, fillingPanel: false)

        #expect(fit.height == 400, "the root's height, held, and not the last screen's 754")
    }

    @Test("a screen being popped is not heard")
    func aScreenBeingPoppedIsNotHeard() {
        let fit = fit()
        fit.show(depth: 1, fillingPanel: false)
        let pushed = fit.nameScreen()
        fit.report(bars: 54, atDepth: 1)
        fit.report(content: 700, from: pushed, atDepth: 1)
        fit.show(depth: 0, fillingPanel: false)

        fit.report(content: 900, from: pushed, atDepth: 1)
        fit.show(depth: 1, fillingPanel: false)

        #expect(fit.height == 400, "nothing was kept for the next screen at that depth")
    }

    /// A preview tapped over another replaces it in place, and the one going
    /// can still be laid out on its way off.
    @Test("of two screens at one depth, the newer is the one heard")
    func theNewerScreenAtADepthIsHeard() {
        let fit = fit()
        fit.show(depth: 1, fillingPanel: false)
        fit.report(bars: 54, atDepth: 1)
        let leaving = fit.nameScreen()
        fit.report(content: 700, from: leaving, atDepth: 1)
        let arriving = fit.nameScreen()
        fit.report(content: 500, from: arriving, atDepth: 1)
        #expect(fit.height == 554)

        fit.report(content: 720, from: leaving, atDepth: 1)

        #expect(fit.height == 554)
    }

    @Test("a screen's contents changing moves the panel with them")
    func followsTheScreenAsItChanges() {
        let fit = fit()
        let root = fit.nameScreen()
        fit.report(content: 400, from: root, atDepth: 0)

        fit.report(content: 472, from: root, atDepth: 0)

        #expect(fit.height == 472)
    }

    /// A pushed screen is laid out before its navigation bar is, and the bar
    /// is taller again once the push has finished.
    @Test("bars that grow raise the panel by as much")
    func followsTheBars() {
        let fit = fit()

        fit.report(bars: 120, atDepth: 0)

        #expect(fit.height == 520)
    }

    @Test("a photo viewer takes the window's height, and gives it back")
    func aPhotoViewerTakesTheWindowsHeight() {
        let fit = fit()

        fit.show(depth: 1, fillingPanel: true)
        #expect(fit.height == nil)

        fit.show(depth: 0, fillingPanel: false)
        #expect(fit.height == 400)
    }

    @Test("a panel taken down forgets what its screens asked")
    func forgetDropsEverything() {
        let fit = fit()

        fit.forget()
        #expect(fit.height == nil)

        fit.report(bars: 0, atDepth: 0)
        #expect(fit.height == nil, "the next panel's screens say what they need themselves")
    }
}
