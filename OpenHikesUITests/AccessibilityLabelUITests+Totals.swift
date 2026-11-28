//
//  AccessibilityLabelUITests+Totals.swift
//  OpenHikesUITests
//
//  What *Totals* reads as. Its figures are drawn in two sizes and its names
//  in small capitals, and none of that is what should be spoken: a figure is
//  one element, named for what it measures, with the whole figure as its
//  value. The audit in `AccessibilityUITests+Totals.swift` can tell that
//  each is reachable, and not that it says the right thing.
//

import XCTest

extension AccessibilityLabelUITests {
    /// The bundled track carries a clock, so it counts as walked. Nothing
    /// here depends on which year its clock is in: the year's distance is
    /// asked only what it is named for, and the rest is everything walked.
    @MainActor
    func testTotalsReadEachFigureAsOneElementNamedForWhatItMeasures() {
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

        // The year's distance is named for its year, which is what tells it
        // from last year's beside it: the color of its dot is color alone.
        let thisYear = element("library-totals-this-year", in: app)
        XCTAssertTrue(thisYear.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertEqual(thisYear.label, String(Calendar.current.component(.year, from: .now)))
        XCTAssertFalse(valueText(of: thisYear).isEmpty, "the year should read its distance as its value")

        XCTAssertEqual(element("library-totals-tile-climb", in: app).label, "Climb")
        XCTAssertEqual(element("library-totals-tile-moving-time", in: app).label, "Moving Time")

        let distance = element("library-totals-all-time-distance", in: app)
        XCTAssertEqual(distance.label, "Distance")
        XCTAssertTrue(
            valueText(of: distance).contains(where: \.isNumber),
            "the row should read its figure whole, got \"\(valueText(of: distance))\""
        )

        // A record is the hike that holds it, and opens it.
        let longest = element("library-record-longest", in: app)
        XCTAssertEqual(longest.label, "Longest")
        XCTAssertTrue(
            valueText(of: longest).hasPrefix(UITestFixture.importedHikeTitle),
            "a record should name its hike, got \"\(valueText(of: longest))\""
        )
        scrollToTap(longest, in: app)
        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle]
                .waitForExistence(timeout: UITestTimeout.navigation),
            "tapping a record should open its hike"
        )
    }

    @MainActor
    private func valueText(of element: XCUIElement) -> String {
        element.value as? String ?? ""
    }
}
