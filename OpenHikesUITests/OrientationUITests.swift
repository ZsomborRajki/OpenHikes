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
    /// How many swipes the share form gets to bring *View Photos* into
    /// reach. A landscape window shows two rows of it at a time.
    private static let formSwipes = 6

    /// How far below the panel's top edge the weather badge may sit before it
    /// has stopped being at the top of the map. Generous — the badge asks for
    /// the panel's own margin — and its job is to catch a portrait-sized drop,
    /// not to pin a padding.
    private static let maximumBadgeDropBelowThePanel: CGFloat = 40

    /// How far above the bottom of the window the credit line may sit in
    /// landscape. Room for the line's own height and its spacing, and nothing
    /// like the height of the sheet it used to leave space for.
    private static let maximumCreditLineLift: CGFloat = 80

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
            element("map-search", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "and should still be usable — searching is what the sheet is for"
        )

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            waitForPortrait(app),
            "the app never returned to portrait"
        )
        XCTAssertTrue(
            map.waitForExistence(timeout: UITestTimeout.navigation),
            "the map should survive the way back out of landscape"
        )
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
        XCTAssertTrue(
            element("trail-map", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
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

    /// A photograph opened in landscape takes the window, as it takes the
    /// whole sheet in portrait — and the panel goes back to being a panel when
    /// the photograph is closed.
    @MainActor
    func testLandscapePhotoViewerFillsTheWindow() {
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
        XCTAssertTrue(app.navigationBars["1 of 3"].waitForExistence(timeout: UITestTimeout.navigation))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        let panel = element("map-side-panel", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                panel.frame.width > app.frame.width * Self.minimumFilledWindowShare
            },
            "the photograph should take the window, not the panel's column"
        )

        app.navigationBars["1 of 3"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle]
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                panel.frame.width < app.frame.width * Self.maximumSheetWidthShare
            },
            "closing the photograph should give the map its half back"
        )
    }

    /// The share form's gallery is full-screen in landscape too: the form is
    /// a sheet, which the system draws across the whole window in compact
    /// height, and the gallery is pushed inside it.
    ///
    /// Opened in landscape rather than rotated into it. The form is presented
    /// from the hike's screen, and a rotation moves that screen from the
    /// portrait sheet to the side panel — a different host — which takes the
    /// form down with the old one.
    @MainActor
    func testLandscapeShareGalleryFillsTheWindow() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        XCUIDevice.shared.orientation = .portrait
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: [
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=3",
            ]
        )
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        openHikeDetail(in: app)
        scrollToTap(element("community-share-button", in: app), in: app)
        // Dragged by coordinate rather than through ``scrollIntoView``, whose
        // container is the first scroll view in the app — in landscape the
        // side panel's, under the form — and rather than through a query for
        // the form's list, which matches on rows that scroll out of it.
        XCTAssertTrue(app.navigationBars["Share Hike"].waitForExistence(timeout: UITestTimeout.navigation))
        let viewPhotos = element("community-share-view-photos", in: app)
        for _ in 0..<Self.formSwipes where !isReachable(viewPhotos, in: app) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        tapWhenReady(viewPhotos)
        XCTAssertTrue(app.navigationBars["1 of 3"].waitForExistence(timeout: UITestTimeout.navigation))

        let gallery = element("community-share-photo-viewer", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                gallery.frame.width > app.frame.width * Self.minimumFilledWindowShare
                    && gallery.frame.height > app.frame.height * Self.minimumFilledWindowShare
            },
            "the share form's gallery should take the window in landscape"
        )
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

            // And at the top of the map, level with the panel beside it.
            //
            // The badge's own top padding is a Dynamic Island's height, which
            // is the right number in portrait and a quarter of the screen here
            // — it left the reading floating in the middle of the map. Held
            // against the panel rather than against a figure, because the
            // margin that decides both belongs to the app and this bundle runs
            // out of process: what is asserted is that they line up.
            XCTAssertGreaterThanOrEqual(
                badge.frame.minY,
                panel.frame.minY,
                "the badge should not climb above the panel it sits beside"
            )
            XCTAssertLessThan(
                badge.frame.minY - panel.frame.minY,
                Self.maximumBadgeDropBelowThePanel,
                "in landscape the badge belongs at the top, not a notch's height down the map"
            )
        }
    }

    /// The other three things a rotation used to get wrong, and the one
    /// argument they share: landscape has no sheet.
    ///
    /// ``MapSidePanel`` takes a leading edge and leaves the bottom of the map
    /// clear, but ``SheetMetrics`` reports nothing there — so the map's own
    /// leading-edge stack fell back on the guess it makes before a sheet has
    /// reported, and parked the credit line and the camera pill a sheet's
    /// height above a sheet that was not there.
    ///
    /// Measured against the map rather than named, the way the panel's width
    /// is above: what went wrong was a frame.
    @MainActor
    func testLandscapePutsTheCreditLineAtTheBottom() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright()
        let credit = element("map-attribution", in: app)
        XCTAssertTrue(
            credit.waitForExistence(timeout: UITestTimeout.navigation),
            "the credit line should be up before the device is turned"
        )
        let panel = element("map-side-panel", in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        XCTAssertTrue(panel.waitForExistence(timeout: UITestTimeout.navigation))

        XCTAssertGreaterThan(
            credit.frame.maxY,
            app.frame.maxY - Self.maximumCreditLineLift,
            "nothing is under the credit line in landscape, so it belongs at the bottom"
        )
        XCTAssertGreaterThanOrEqual(
            credit.frame.minX,
            panel.frame.maxX,
            "and beside the panel rather than behind it"
        )
    }
}

// MARK: - Shared with the gallery tests

// Out of the class body, where `test_case_accessibility` would have them
// private, because `OrientationUITests+Gallery.swift` stands on them too.
extension OrientationUITests {
    /// The most of the screen's width the sheet's contents may take before the
    /// map has stopped being the thing on screen. Half is generous — the panel
    /// asks for well under it on every iPhone — and it is the assertion's job
    /// to catch a sheet that has taken the window, not to pin a width.
    static let maximumSheetWidthShare: CGFloat = 0.5

    /// The least of the window a full-screen photograph's container may
    /// measure. Less than all of it, because the container is laid out inside
    /// the safe area — the Dynamic Island's edge and the home indicator's —
    /// while the black behind the picture runs on past it.
    static let minimumFilledWindowShare: CGFloat = 0.8

    // MARK: - Turning the device

    /// Launches with the device upright, whatever was left behind.
    ///
    /// The simulator keeps the orientation it was last put in — across test
    /// classes, and across runs, including one that was killed before its
    /// teardown — so upright is a precondition to establish rather than one to
    /// assume. The teardown blocks above are what the *next* class gets; this
    /// is what this one stands on.
    @MainActor
    func launchUpright(arguments: [String] = []) -> XCUIApplication {
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
    func waitForLandscape(_ app: XCUIApplication) -> Bool {
        wait(for: app) { $0.width > $0.height }
    }

    @MainActor
    func waitForPortrait(_ app: XCUIApplication) -> Bool {
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
