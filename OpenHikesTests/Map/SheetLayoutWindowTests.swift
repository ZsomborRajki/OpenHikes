//
//  SheetLayoutWindowTests.swift
//  OpenHikesTests
//
//  Which shape the map screen takes in which window — see
//  ``SheetLayout/init(windowSize:isCompactHeight:)``, which is the whole rule.
//
//  The sizes stand for the space the screen is laid out in, inside the safe
//  area, on the devices they are named after — an iPhone 18 Pro, the iPhone
//  Duo's cover (466 × 678 points) and inner (669 × 951) displays, and an iPad
//  Pro 13-inch (1032 × 1376) and iPad mini (744 × 1133) — with roughly their
//  bars and home indicator taken off. Roughly is enough: the rule never sees a
//  device, only the window's width and whether its height is compact, so
//  neither do these.
//

@testable import OpenHikes
import SwiftUI
import Testing

@MainActor
@Suite("Sheet layout for a window")
struct SheetLayoutWindowTests {
    @Test("a phone held upright keeps the sheet")
    func portraitPhoneKeepsTheSheet() {
        let layout = SheetLayout(windowSize: CGSize(width: 402, height: 794), isCompactHeight: false)
        #expect(layout == .bottomSheet)
    }

    /// The case the panel was built for, and not a choice: at a compact height
    /// the system presents the sheet over the whole map.
    @Test("a compact height takes the panel, however narrow the window")
    func compactHeightTakesThePanel() {
        let phone = SheetLayout(windowSize: CGSize(width: 667, height: 375), isCompactHeight: true)
        #expect(phone == .sidePanel)
        let closedDuoOnItsSide = SheetLayout(windowSize: CGSize(width: 600, height: 445), isCompactHeight: true)
        #expect(closedDuoOnItsSide == .sidePanel)
    }

    /// The iPhone Duo opened flat in landscape is of regular height, which is
    /// how it used to end up with the sheet as a card in the middle of its
    /// bottom edge.
    @Test("an unfolded iPhone Duo in landscape takes the panel")
    func unfoldedDuoInLandscapeTakesThePanel() {
        let layout = SheetLayout(windowSize: CGSize(width: 897, height: 649), isCompactHeight: false)
        #expect(layout == .sidePanel)
    }

    @Test("an iPhone Duo held upright keeps the sheet, open or closed")
    func uprightDuoKeepsTheSheet() {
        let inner = SheetLayout(windowSize: CGSize(width: 669, height: 897), isCompactHeight: false)
        #expect(inner == .bottomSheet)
        let cover = SheetLayout(windowSize: CGSize(width: 412, height: 657), isCompactHeight: false)
        #expect(cover == .bottomSheet)
    }

    /// Wider than tall is not enough on its own: a window whose map would be
    /// narrower than the panel beside it does better with the sheet, which
    /// spends the width on the map.
    @Test("a window too narrow for a map beside the panel keeps the sheet")
    func narrowWideWindowKeepsTheSheet() {
        let threshold = SheetLayout.minimumPanelWindowWidth
        let atThreshold = SheetLayout(
            windowSize: CGSize(width: threshold, height: threshold - 100),
            isCompactHeight: false
        )
        #expect(atThreshold == .sidePanel)
        let belowIt = SheetLayout(
            windowSize: CGSize(width: threshold - 1, height: threshold - 100),
            isCompactHeight: false
        )
        #expect(belowIt == .bottomSheet)
    }

    /// The shape the rule used to ask about, and the reason it stopped: at
    /// this width a sheet is a card in the middle of the bottom edge rather
    /// than a sheet across the window, whichever way the window is longer.
    @Test("a window with room for the map beside the panel takes it, whatever its shape")
    func roomyWindowTakesThePanelWhateverItsShape() {
        let square = SheetLayout(windowSize: CGSize(width: 900, height: 900), isCompactHeight: false)
        #expect(square == .sidePanel)
        let upright = SheetLayout(
            windowSize: CGSize(width: SheetLayout.minimumPanelWindowWidth, height: 1200),
            isCompactHeight: false
        )
        #expect(upright == .sidePanel)
    }

    /// An iPad is of regular height either way up and wider than the
    /// threshold either way up, so a rotation leaves the panel where it is —
    /// the way Maps keeps its own.
    @Test("an iPad takes the panel either way up", arguments: [
        CGSize(width: 1032, height: 1332),
        CGSize(width: 1376, height: 988),
        CGSize(width: 744, height: 1089),
        CGSize(width: 1133, height: 700),
    ])
    func iPadTakesThePanelEitherWayUp(window: CGSize) {
        #expect(SheetLayout(windowSize: window, isCompactHeight: false) == .sidePanel)
    }

    /// Beside another app an iPad window can be as narrow as a phone, and
    /// then it is drawn as one: a sheet across the window's width.
    @Test("an iPad window narrowed beside another app keeps the sheet", arguments: [
        CGSize(width: 320, height: 1332),
        CGSize(width: 507, height: 1332),
        CGSize(width: 683, height: 988),
    ])
    func narrowedIPadWindowKeepsTheSheet(window: CGSize) {
        #expect(SheetLayout(windowSize: window, isCompactHeight: false) == .bottomSheet)
    }

    /// The threshold is the panel's own numbers rather than one of its own, so
    /// widening the panel moves it with it.
    @Test("the threshold leaves the map at least as wide as the panel")
    func thresholdLeavesTheMapAsWideAsThePanel() {
        let mapWidth = SheetLayout.minimumPanelWindowWidth - MapSidePanelLayout.mapInset
        #expect(mapWidth >= MapSidePanelLayout.mapInset)
    }
}
