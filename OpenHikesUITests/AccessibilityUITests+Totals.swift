//
//  AccessibilityUITests+Totals.swift
//  OpenHikesUITests
//
//  The library's *Totals*: the figures, the month chart and the records.
//  In the sweep from the day it exists, because a screen added outside it is
//  what #662 had to go back for.
//

import XCTest

extension AccessibilityUITests {
    /// The bundled track carries a clock, so it counts as walked and the
    /// screen has a year's figures, a chart and a record to audit.
    @MainActor
    func testLibraryTotalsPassAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        let totals = element("library-totals-button", in: app)
        XCTAssertTrue(totals.waitForExistence(timeout: UITestTimeout.existence))
        totals.tap()
        XCTAssertTrue(
            element("library-month-chart", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the totals should open on this year's chart"
        )
        XCTAssertTrue(
            element("library-record-longest", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "a walked hike is the longest walk of a library of one"
        )

        try audit(app)
    }
}
