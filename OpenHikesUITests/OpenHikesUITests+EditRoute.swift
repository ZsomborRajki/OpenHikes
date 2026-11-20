//
//  OpenHikesUITests+EditRoute.swift
//  OpenHikesUITests
//
//  *Edit Route* on a hike that was recorded or imported: the stretch that was
//  not walked comes off in one tap, the save lands on the same hike, and
//  *Revert to Original* puts it back.
//
//  The fixture is a kilometre on foot and then six at a car's pace, which is
//  the recording nobody stopped at the car park. A GPX file carries no motion
//  tag, so what finds its drive is the speed between its points.
//

import XCTest

extension OpenHikesUITests {
    private static let driveFixture = UITestFixture.walkThenDriveName
    private static let driveTitle = UITestFixture.walkThenDriveTitle

    @MainActor
    func testADriveIsCutOffAHikeAndPutBack() {
        let app = launchApp(
            arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=\(Self.driveFixture)"]
        )
        openHikeDetail(in: app, titled: Self.driveTitle)

        openEditRoute(in: app)
        let removeDrive = element("route-trim-remove-end", in: app)
        XCTAssertTrue(
            removeDrive.waitForExistence(timeout: UITestTimeout.existence),
            "a hike that ends with a drive should offer to take it off"
        )
        XCTAssertFalse(element("route-trim-save", in: app).isEnabled, "nothing is cut yet, so nothing to save")
        XCTAssertFalse(element("route-trim-revert", in: app).exists, "a hike never edited has no original")

        removeDrive.tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { !removeDrive.exists },
            "the offer goes once its stretch is cut"
        )
        let save = element("route-trim-save", in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(
            app.navigationBars[Self.driveTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "saving should come back to the same hike"
        )

        // The hike is now the walk alone: nothing left to offer, and an
        // original to go back to.
        openEditRoute(in: app)
        let revert = element("route-trim-revert", in: app)
        XCTAssertTrue(revert.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertFalse(element("route-trim-remove-end", in: app).exists)

        scrollToTap(revert, in: app)
        let confirm = app.buttons["Revert"]
        XCTAssertTrue(confirm.waitForExistence(timeout: UITestTimeout.existence))
        confirm.tap()
        XCTAssertTrue(app.navigationBars[Self.driveTitle].waitForExistence(timeout: UITestTimeout.navigation))

        openEditRoute(in: app)
        XCTAssertTrue(
            element("route-trim-remove-end", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the original has its drive again"
        )
        XCTAssertFalse(element("route-trim-revert", in: app).exists)
    }

    /// The trimmer under the map: its end handle dragged back along the
    /// chart cuts the line there.
    @MainActor
    func testDraggingTheChartsHandleTrimsTheRoute() {
        let app = launchApp(
            arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=\(Self.driveFixture)"]
        )
        openHikeDetail(in: app, titled: Self.driveTitle)
        openEditRoute(in: app)
        let end = element("route-trim-end", in: app)
        let start = element("route-trim-start", in: app)
        XCTAssertTrue(end.waitForExistence(timeout: UITestTimeout.existence))
        let whole = end.value as? String ?? ""
        XCTAssertFalse(element("route-trim-save", in: app).isEnabled)

        // Halfway back towards the start handle.
        let grip = end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let halfway = grip.withOffset(CGVector(dx: (start.frame.midX - end.frame.midX) / 2, dy: 0))
        grip.press(forDuration: 0.5, thenDragTo: halfway)

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { element("route-trim-save", in: app).isEnabled },
            "a handle dragged off its end is a cut to save"
        )
        XCTAssertNotEqual(end.value as? String ?? "", whole, "the handle says where it stands now")
    }

    /// The same cut made on the map: a press on the line's end handle takes
    /// hold of it, and it slides back along the line under the finger.
    @MainActor
    func testDraggingTheMapsHandleTrimsTheRoute() {
        let app = launchApp(
            arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=\(Self.driveFixture)"]
        )
        openHikeDetail(in: app, titled: Self.driveTitle)
        openEditRoute(in: app)
        let end = element("route-trim-end-handle", in: app)
        let start = element("route-trim-start-handle", in: app)
        XCTAssertTrue(end.waitForExistence(timeout: UITestTimeout.existence), "the map draws a handle on each end")
        XCTAssertTrue(start.exists)
        XCTAssertFalse(element("route-trim-save", in: app).isEnabled)

        // Along the drive, which runs level across the map, back towards
        // where it began.
        let grip = end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let back = grip.withOffset(CGVector(dx: (start.frame.midX - end.frame.midX) / 2, dy: 0))
        grip.press(forDuration: 0.5, thenDragTo: back)

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { element("route-trim-save", in: app).isEnabled },
            "a handle dragged along the line is a cut to save"
        )
    }
}
