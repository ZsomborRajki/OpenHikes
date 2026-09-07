//
//  OrientationUITests.swift
//  OpenHikesUITests
//
//  The one orientation nothing here used to run in.
//
//  The app declares landscape and could not draw it: `.presentationDetents`
//  are honoured only in a compact-width, regular-height presentation, so in
//  compact height the system presented `MapSheet` full-screen — and because
//  `OpenHikesView` keeps that sheet up permanently and puts it back whenever it
//  is dismissed, that was the entire UI. A white sheet with a search field on
//  it, no map anywhere, and no gesture, button or state that brought one back
//  short of rotating the phone again. Landscape draws a side panel now.
//
//  Measured rather than named, the way the collapsed sheet is in
//  `PhotoUITests`: what went wrong was a frame, so what is asserted is a frame.
//  The sheet covering the window is exactly the shape of the bug, and it is
//  what a passing run has to rule out.
//

import XCTest

nonisolated final class OrientationUITests: XCTestCase {
    /// The most of the screen's width the sheet's contents may take before the
    /// map has stopped being the thing on screen. Half is generous — the panel
    /// asks for well under it on every iPhone — and it is the assertion's job
    /// to catch a sheet that has taken the window, not to pin a width.
    private static let maximumSheetWidthShare: CGFloat = 0.5

    /// Landscape puts the map beside the sheet's contents rather than behind
    /// them, and portrait puts the sheet back over it.
    @MainActor
    func testLandscapeKeepsTheMapVisibleBesideTheSheet() {
        addTeardownBlock {
            // Whatever happened above, the next class starts upright: the
            // simulator keeps the orientation it was left in, and every other
            // suite in this bundle asserts against a portrait screen.
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }

        let app = launchUpright()
        let map = element("trail-map", in: app)
        XCTAssertTrue(
            map.waitForExistence(timeout: UITestTimeout.navigation),
            "the map should be up before the device is turned"
        )
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: UITestTimeout.navigation))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitForLandscape(app),
            "the app never adopted the landscape window it declares support for"
        )

        XCTAssertTrue(map.exists, "the map should have survived the rotation")
        XCTAssertTrue(
            map.isHittable,
            "and should still be there to be panned, not covered by a sheet"
        )
        XCTAssertEqual(
            map.frame,
            app.frame,
            "and should have the whole window, as it does in portrait"
        )

        // The sheet is not presented in landscape, so `map-sheet` is not the
        // thing to measure: the contents are in a panel, and the panel's width
        // is the assertion. A build without the fix fails on its absence
        // before it gets here.
        let panel = element("map-side-panel", in: app)
        XCTAssertTrue(
            panel.exists,
            "landscape should draw the sheet's contents as a side panel"
        )
        XCTAssertLessThan(
            panel.frame.width,
            app.frame.width * Self.maximumSheetWidthShare,
            "the sheet's contents should sit beside the map, not over it"
        )
        XCTAssertTrue(
            element("map-search", in: app).exists,
            "and should still be usable — searching is what the sheet is for"
        )

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            waitForPortrait(app),
            "the app never returned to portrait"
        )
        XCTAssertTrue(map.exists)
        XCTAssertTrue(
            sheet.waitForExistence(timeout: UITestTimeout.navigation),
            "the sheet should be presented again on the way back"
        )
        XCTAssertFalse(
            element("map-side-panel", in: app).exists,
            "and the panel should have gone with the landscape it belongs to"
        )
    }

    /// Rotating a hike's own screen keeps it: the panel hosts the same
    /// navigation stack the sheet does, so what was pushed is still pushed.
    @MainActor
    func testLandscapeKeepsThePushedHikeScreen() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }

        let app = launchUpright(
            arguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))

        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle]
                .waitForExistence(timeout: UITestTimeout.navigation),
            "the hike's screen should still be the one on top"
        )
        XCTAssertTrue(element("trail-map", in: app).exists)
    }

    @MainActor
    func testRotationKeepsTheSelectedHistorySegment() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-walks=HalfLoop",
        ])
        openHikeDetail(in: app)
        let history = app.segmentedControls["walk-segment"].buttons["History"]
        history.tap()
        XCTAssertTrue(history.isSelected)
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(orientation == .portrait ? waitForPortrait(app) : waitForLandscape(app))
            XCTAssertTrue(history.waitForExistence(timeout: UITestTimeout.navigation))
            XCTAssertTrue(history.isSelected, "rotation must preserve the selected section")
        }
    }

    @MainActor
    func testRotationKeepsTheCurrentPhoto() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-photos=3",
        ])
        openHikeDetail(in: app)
        XCTAssertTrue(scrollIntoView(element("hike-photo-strip", in: app), in: app))
        photoTile(at: 1, of: 3, in: app).tap()
        let next = app.buttons["Next photo"]
        XCTAssertTrue(next.waitForExistence(timeout: UITestTimeout.navigation))
        next.tap()
        XCTAssertTrue(app.navigationBars["2 of 3"].waitForExistence(timeout: UITestTimeout.navigation))
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(orientation == .portrait ? waitForPortrait(app) : waitForLandscape(app))
            XCTAssertTrue(app.navigationBars["2 of 3"].waitForExistence(timeout: UITestTimeout.navigation))
        }
        // The restored scroll position must also drive subsequent paging.
        next.tap()
        XCTAssertTrue(app.navigationBars["3 of 3"].waitForExistence(timeout: UITestTimeout.navigation))
    }

    @MainActor
    func testLandscapeWeatherClearsThePanel() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: ["--ui-test-weather"])
        let badge = element("weather-badge", in: app)
        XCTAssertTrue(badge.waitForExistence(timeout: UITestTimeout.navigation))
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(waitForLandscape(app))
            let panel = element("map-side-panel", in: app)
            XCTAssertTrue(panel.waitForExistence(timeout: UITestTimeout.navigation))
            XCTAssertGreaterThanOrEqual(badge.frame.minX, panel.frame.maxX)
            XCTAssertLessThanOrEqual(badge.frame.maxX, app.frame.maxX)
            XCTAssertTrue(badge.isHittable)
        }
    }

    // MARK: - Turning the device

    /// Launches with the device upright, whatever was left behind.
    ///
    /// The simulator keeps the orientation it was last put in — across test
    /// classes, and across runs, including one that was killed before its
    /// teardown — so upright is a precondition to establish rather than one to
    /// assume. The teardown blocks above are what the *next* class gets; this
    /// is what this one stands on.
    @MainActor
    private func launchUpright(arguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = launchApp(arguments: arguments)
        XCTAssertTrue(waitForPortrait(app), "the app should have started upright")
        return app
    }

    // MARK: - Waiting on the rotation

    /// Waits for the window itself to have turned.
    ///
    /// The app's frame is the effect a rotation has — a duration is not, and
    /// the accessibility tree answers with the old geometry until the system
    /// has finished laying out the new one.
    @MainActor
    private func waitForLandscape(_ app: XCUIApplication) -> Bool {
        wait(for: app) { $0.width > $0.height }
    }

    @MainActor
    private func waitForPortrait(_ app: XCUIApplication) -> Bool {
        wait(for: app) { $0.height > $0.width }
    }

    @MainActor
    private func wait(
        for app: XCUIApplication,
        until isSettled: @escaping (CGRect) -> Bool
    ) -> Bool {
        let turned = NSPredicate { _, _ in isSettled(app.frame) }
        let settled = expectation(for: turned, evaluatedWith: app)
        return XCTWaiter.wait(
            for: [settled],
            timeout: UITestTimeout.navigation
        ) == .completed
    }
}
