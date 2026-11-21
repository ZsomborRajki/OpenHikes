//
//  AccessibilityUITests+EditRoute.swift
//  OpenHikesUITests
//
//  *Edit Route* on a hike that was recorded or imported: the trimmer's two
//  handles, the figures under it, the offer to take off a stretch that was
//  not walked, and the sections of a recording the hiker can answer for.
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

    /// The sections to check, which is the one place in the app where a
    /// decision is drawn as a checkmark.
    ///
    /// A choice that reads as two identical unnamed rows is unusable without
    /// sight, and this card has no second way to tell them apart: the
    /// difference between them is the shape of a line on a map. The notice
    /// that leads here is swept on the way, on the hike's own screen.
    @MainActor
    func testRouteChecksAreReadable() throws {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph=\(UITestFixture.trailGraphName)",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.reviewableTrace[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        walkRecordedTrace(UITestFixture.reviewableTrace, countedBy: points)
        stopRecording(named: Self.checkedHikeName, in: app)
        XCTAssertTrue(
            app.navigationBars[Self.checkedHikeName].waitForExistence(timeout: Self.checkTimeout),
            "a snapped recording should be saved at once"
        )
        let notice = element("hike-route-check", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(
            notice.label.hasPrefix("Check Route"),
            "the notice is one element that says what it is for, said \"\(notice.label)\""
        )
        try audit(app)

        openRouteChecks(in: app, saying: "1 section to check")
        let keepTrail = element("review-choice-trail", in: app)
        let useGPS = element("review-choice-gps", in: app)
        XCTAssertTrue(keepTrail.waitForExistence(timeout: Self.checkTimeout))
        XCTAssertFalse(
            keepTrail.label.isEmpty,
            "each option has to name the line it would keep"
        )
        XCTAssertFalse(useGPS.label.isEmpty)
        XCTAssertTrue(
            keepTrail.isSelected,
            "the standing choice is drawn as a checkmark, which is decoration "
                + "— the trait is what carries it"
        )
        XCTAssertFalse(useGPS.isSelected)

        try audit(app)
    }

    /// Reading a saved line and its trace back is real work on a cold
    /// simulator.
    private static let checkTimeout: TimeInterval = 30
    private static let checkedHikeName = "Checked Route"
}
