//
//  AccessibilityUITests+OfflineMaps.swift
//  OpenHikesUITests
//
//  *Offline Maps*: a search field, an order capsule, two switches and a list
//  whose every row carries its own download button, and a downloaded row
//  what the switches offer to add to it or delete. With no server a launch
//  running tests has nothing in it, so this sweeps the stand-in lists
//  ``SeededOfflineCountryServer`` serves; nothing downloads.
//

import XCTest

extension AccessibilityUITests {
    /// Swept as it opens, at the sheet's middle, over the map.
    ///
    /// Not at the sheet's full height, where the list by name draws its
    /// letters down the trailing edge: that index is UIKit's
    /// `UIIndexBarAccessoryView`, which SwiftUI draws 15 points wide and the
    /// audit calls too small to hit. Nothing the app sets sizes it, and
    /// filtering it would widen what the sweep ignores, so the sweep stays at
    /// the height the index is put away at (`sectionIndexLetter`).
    @MainActor
    func testOfflineMapsPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: OfflineMapsFixture.seededArguments)
        openOfflineMaps(in: app)
        XCTAssertTrue(
            element("offline-country-AT", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the audit is worth nothing against a list that has not loaded"
        )
        try audit(app)
    }

    /// A downloaded country's row with an offer under its name, which no
    /// launch that holds nothing draws: with *Extra Detail* off, Slovenia
    /// offers to delete its zoom 15.
    ///
    /// Largest first, because the row is under the fold at the sheet's
    /// middle, and scrolling to it raises the sheet to the height the list
    /// by name draws its letters at, which the sweep above stays clear of.
    /// Largest first has no letters at any height.
    @MainActor
    func testOfflineMapsDownloadedRowPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: OfflineMapsFixture.downloadedArguments)
        openOfflineMaps(in: app)
        XCTAssertTrue(element("offline-country-SI", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        // Flipped while the list is at its head: scrolled, the switch
        // slides under the search field.
        let extraDetail = app.switches.matching(identifier: "offline-maps-extra-detail").firstMatch
        extraDetail.coordinate(withNormalizedOffset: OfflineMapsFixture.switchKnob).tap()
        let order = element("offline-maps-order-button", in: app)
        tapWhenReady(order)
        tapWhenReady(app.buttons["Largest"])
        XCTAssertTrue(waitUntil { (order.value as? String) == "Largest" }, "the list should be largest first")
        let offer = element("offline-country-SI-remove", in: app)
        XCTAssertTrue(
            offer.waitForExistence(timeout: UITestTimeout.navigation),
            "the audit is worth nothing against a row with no offer on it"
        )
        XCTAssertTrue(scrollIntoView(offer, in: app), "the offer should be on screen when the row is swept")
        try audit(app)
    }
}
