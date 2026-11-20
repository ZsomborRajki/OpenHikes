//
//  AccessibilityUITests+EditRoute.swift
//  OpenHikesUITests
//
//  *Edit Route* on a hike that was recorded or imported: the trimmer's two
//  handles, the figures under it and the offer to take off a stretch that was
//  not walked.
//

import XCTest

extension AccessibilityUITests {
    /// The fixture ends with a drive, so the screen is audited with its offer
    /// drawn.
    @MainActor
    func testEditRoutePassesAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.walkThenDriveName)",
            ]
        )
        openHikeDetail(in: app, titled: UITestFixture.walkThenDriveTitle)
        openEditRoute(in: app)
        XCTAssertTrue(
            element("route-trim-remove-end", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the line should be measured, and its drive offered, before the audit"
        )
        let end = element("route-trim-end", in: app)
        XCTAssertTrue(end.exists)
        XCTAssertEqual(end.label, "End of route")
        XCTAssertFalse((end.value as? String ?? "").isEmpty, "a handle says how far along the route it stands")

        try audit(app)
    }
}
