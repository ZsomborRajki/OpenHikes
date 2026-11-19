//
//  AccessibilityUITests+OfflineMaps.swift
//  OpenHikesUITests
//
//  *Offline Maps*: a search field, an order capsule, a switch and a list
//  whose every row carries its own download button. With no server a
//  launch running tests has nothing in it, so this sweeps the stand-in list
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
}
