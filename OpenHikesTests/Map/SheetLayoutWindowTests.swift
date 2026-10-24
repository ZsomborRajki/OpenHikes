//
//  SheetLayoutWindowTests.swift
//  OpenHikesTests
//
//  Which shape the map screen takes in which window — see
//  ``SheetLayout/init(windowSize:isCompactHeight:)``, which is the whole rule.
//
//  The sizes stand for the space the screen is laid out in, inside the safe
//  area, on the devices they are named after — an iPhone 18 Pro, and the
//  iPhone Duo's cover (466 × 678 points) and inner (669 × 951) displays — with
//  roughly their bars and home indicator taken off. Roughly is enough: the
//  rule never sees a device, only which way the window is longer and whether
//  it clears the panel's threshold, so neither do these.
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
    @Test("a wide window too narrow for a map beside the panel keeps the sheet")
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

    @Test("a square window keeps the sheet")
    func squareWindowKeepsTheSheet() {
        let layout = SheetLayout(windowSize: CGSize(width: 900, height: 900), isCompactHeight: false)
        #expect(layout == .bottomSheet)
    }

    /// The threshold is the panel's own numbers rather than one of its own, so
    /// widening the panel moves it with it.
    @Test("the threshold leaves the map at least as wide as the panel")
    func thresholdLeavesTheMapAsWideAsThePanel() {
        let mapWidth = SheetLayout.minimumPanelWindowWidth - MapSidePanelLayout.mapInset
        #expect(mapWidth >= MapSidePanelLayout.mapInset)
    }
}
