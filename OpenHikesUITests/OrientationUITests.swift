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

        let app = launchApp()
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

        let app = launchApp(
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
