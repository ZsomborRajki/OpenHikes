//
//  OpenHikesUITests+EditRouteSteps.swift
//  OpenHikesUITests
//
//  *Edit Route* beyond the two cuts: a stretch picked out and straightened,
//  the whole route turned round, and the line held on the map and pulled
//  through another spot — each taken back with *Undo*, and kept by a save.
//
//  The fixture is the walk-then-drive import: a kilometre north on foot and
//  then a drive east, level across the map, which gives a pull a stretch of
//  line whose place on screen can be read off the end handle.
//

import XCTest

extension OpenHikesUITests {
    private static let stepsFixture = UITestFixture.walkThenDriveName
    private static let stepsTitle = UITestFixture.walkThenDriveTitle
    /// How long a finger rests on the line before it takes hold of it, and
    /// a little more.
    private static let pullPress: TimeInterval = 0.8
    /// How far the line is pulled off itself, in points.
    private static let pullDistance: CGFloat = 70

    @MainActor
    private func openStepsFixture() -> XCUIApplication {
        let app = launchApp(
            arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=\(Self.stepsFixture)"]
        )
        openHikeDetail(in: app, titled: Self.stepsTitle)
        openEditRoute(in: app)
        XCTAssertTrue(
            element("route-trim-end", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the line should be measured before anything is done to it"
        )
        return app
    }

    @MainActor
    func testAStretchIsStraightenedUndoneAndKept() {
        let app = openStepsFixture()
        let save = element("route-trim-save", in: app)
        let begin = element("route-stretch-begin", in: app)
        scrollToTap(begin, in: app, attempts: 8)

        let straighten = element("route-stretch-straighten", in: app)
        XCTAssertTrue(
            straighten.waitForExistence(timeout: UITestTimeout.existence),
            "picking a stretch out offers what can be done with it"
        )
        XCTAssertFalse(save.isEnabled, "a stretch picked out is nothing to save yet")
        XCTAssertFalse(begin.exists, "one question at a time")
        scrollToTap(straighten, in: app, attempts: 8)

        let undo = element("route-step-undo", in: app)
        XCTAssertTrue(undo.waitForExistence(timeout: UITestTimeout.existence), "a step made is a step to take back")
        XCTAssertTrue(waitUntil { save.isEnabled }, "and a change to save")
        scrollToTap(undo, in: app, attempts: 8)
        XCTAssertTrue(waitUntil { !save.isEnabled }, "taken back, there is nothing to save")
        XCTAssertTrue(undo.waitForNonExistence(timeout: UITestTimeout.navigation))

        scrollToTap(element("route-stretch-begin", in: app), in: app, attempts: 8)
        scrollToTap(element("route-stretch-straighten", in: app), in: app, attempts: 8)
        XCTAssertTrue(waitUntil { save.isEnabled })
        save.tap()
        XCTAssertTrue(
            app.navigationBars[Self.stepsTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "saving should come back to the same hike"
        )

        openEditRoute(in: app)
        XCTAssertTrue(
            element("route-step-undo", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the step is kept with the hike, to take back on any visit"
        )
        XCTAssertTrue(element("route-trim-revert", in: app).exists, "and the original is kept to go back to")
    }

    @MainActor
    func testAStretchLeftAloneChangesNothing() {
        let app = openStepsFixture()
        scrollToTap(element("route-stretch-begin", in: app), in: app, attempts: 8)
        let cancel = element("route-stretch-cancel", in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: UITestTimeout.existence))
        let start = element("route-trim-start", in: app)
        XCTAssertEqual(start.label, "Start of stretch", "the handles say what they pick out")

        scrollToTap(cancel, in: app, attempts: 8)

        XCTAssertTrue(element("route-stretch-begin", in: app).waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(waitUntil { start.label == "Start of route" })
        XCTAssertFalse(element("route-trim-save", in: app).isEnabled)
        XCTAssertFalse(element("route-step-undo", in: app).exists)
    }

    @MainActor
    func testTheWholeRouteIsTurnedRound() {
        let app = openStepsFixture()
        let save = element("route-trim-save", in: app)
        scrollToTap(element("route-whole-menu", in: app), in: app, attempts: 8)
        let reverse = app.buttons["Reverse"]
        XCTAssertTrue(reverse.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(app.buttons["Out and Back"].exists, "a line that ends somewhere else can be doubled back")
        XCTAssertTrue(app.buttons["Close Loop"].exists)
        reverse.tap()

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { save.isEnabled },
            "a route turned round is a change"
        )
        let undo = element("route-step-undo", in: app)
        XCTAssertTrue(undo.waitForExistence(timeout: UITestTimeout.existence))
        // A line turned round has no clock, and the drive was told from the
        // walk by its speed: there is nothing to offer until it is undone.
        let removeDrive = element("route-trim-remove-end", in: app)
        XCTAssertTrue(removeDrive.waitForNonExistence(timeout: UITestTimeout.navigation))

        scrollToTap(undo, in: app, attempts: 8)

        XCTAssertTrue(
            removeDrive.waitForExistence(timeout: UITestTimeout.existence),
            "taken back, the route has its clock and its drive again"
        )
        XCTAssertTrue(waitUntil { !save.isEnabled })
    }

    /// The line held on the map and pulled off itself: the stretch under the
    /// finger is redrawn through where it is lifted.
    @MainActor
    func testPullingTheLineRedrawsAStretch() {
        let app = openStepsFixture()
        let end = element("route-trim-end-handle", in: app)
        let start = element("route-trim-start-handle", in: app)
        XCTAssertTrue(end.waitForExistence(timeout: UITestTimeout.existence), "the map draws a handle on each end")
        let save = element("route-trim-save", in: app)
        XCTAssertFalse(save.isEnabled)

        // On the drive, which runs level across the map from the end handle
        // back towards the walk: halfway along it.
        let grip = end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: (start.frame.midX - end.frame.midX) / 2, dy: 0))
        let pulled = grip.withOffset(CGVector(dx: 0, dy: Self.pullDistance))
        grip.press(forDuration: Self.pullPress, thenDragTo: pulled)

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { save.isEnabled },
            "a line pulled off itself is a stretch redrawn, and a change to save"
        )
        XCTAssertTrue(element("route-step-undo", in: app).waitForExistence(timeout: UITestTimeout.existence))
    }
}
