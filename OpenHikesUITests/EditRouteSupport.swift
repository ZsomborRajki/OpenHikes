//
//  EditRouteSupport.swift
//  OpenHikesUITests
//
//  What the suites about *Edit Route* share: the fixture that has something
//  to cut, and the way to the screen. Its own file because
//  `UITestSupport.swift` is at the length the linter allows.
//

import XCTest

nonisolated extension UITestFixture {
    /// A kilometre on foot and then six at a car's pace: the recording nobody
    /// stopped at the car park, which *Edit Route* offers to cut. Imported
    /// through `--ui-test-import-gpx`.
    static let walkThenDriveName = "ThumseeWalkThenDrive"
    static let walkThenDriveTitle = "Thumsee Walk Then Drive (simulated)"
}

extension XCTestCase {
    /// From the open detail of any hike — recorded, imported or drawn —
    /// pushes *Edit Route*, which is in the list that closes the card, below
    /// the fold.
    @MainActor
    func openEditRoute(in app: XCUIApplication) {
        let editRoute = element("hike-edit-route", in: app)
        XCTAssertTrue(
            editRoute.waitForExistence(timeout: UITestTimeout.existence),
            "a hike with a line should offer Edit Route"
        )
        scrollToTap(editRoute, in: app, attempts: 12)
        XCTAssertTrue(app.navigationBars["Edit Route"].waitForExistence(timeout: UITestTimeout.navigation))
    }

    /// From the open detail of a recording that was saved with something to
    /// look at, pushes *Edit Route* through the notice that says so.
    ///
    /// - Parameter expected: what the notice has to say, in part.
    @MainActor
    func openRouteChecks(in app: XCUIApplication, saying expected: String) {
        let notice = element("hike-route-check", in: app)
        XCTAssertTrue(
            notice.waitForExistence(timeout: UITestTimeout.existence),
            "a recording the matcher moved should say there is something to check"
        )
        XCTAssertTrue(
            notice.label.contains(expected),
            "the notice should say \"\(expected)\", said \"\(notice.label)\""
        )
        scrollToTap(notice, in: app)
        XCTAssertTrue(app.navigationBars["Edit Route"].waitForExistence(timeout: UITestTimeout.navigation))
    }
}
