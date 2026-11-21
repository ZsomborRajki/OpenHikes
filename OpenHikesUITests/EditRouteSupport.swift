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
    /// From the open detail of a hike that was recorded or imported, pushes
    /// *Edit Route*, which is in the list that closes the card, below the
    /// fold.
    @MainActor
    func openEditRoute(in app: XCUIApplication) {
        let editRoute = element("hike-edit-route", in: app)
        XCTAssertTrue(
            editRoute.waitForExistence(timeout: UITestTimeout.existence),
            "a hike that was imported should offer Edit Route"
        )
        scrollToTap(editRoute, in: app, attempts: 12)
        XCTAssertTrue(app.navigationBars["Edit Route"].waitForExistence(timeout: UITestTimeout.navigation))
    }
}
