//
//  AccessibilityUITests.swift
//  OpenHikesUITests
//
//  The sweep, run once per screen.
//
//  `performAccessibilityAudit` walks the live element tree and reports
//  unlabelled controls, clipped text at large type sizes, contrast failures
//  and hit regions too small to reach — the class of regression that arrives
//  quietly, in a view nobody thought to re-check. It is per screen rather than
//  once because it only ever sees what is on screen at the time, which is why
//  a screen with no test here has no coverage at all.
//
//  What the audit cannot know — that a tile-provider row is *the selected*
//  one, that the elevation graph reads out the point under the tracker — is
//  asserted in ``AccessibilityLabelUITests`` instead. The exclusions, and the
//  argument for each, live in `AccessibilityAuditSupport.swift`.
//
//  Out-of-process, so nothing here can import the app; screens are reached
//  with the same launch arguments and helpers the functional tests use (see
//  `UITestSupport.swift`).
//

import XCTest

nonisolated final class AccessibilityUITests: XCTestCase {
    /// The first screen: the map, the weather badge and the sheet's search
    /// row. Element detection is the check that matters most here, since two
    /// of the controls are glyph-only buttons.
    @MainActor
    func testMapAndSheetPassAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)

        try audit(app)
    }

    @MainActor
    func testHikeDetailPassesAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)
        XCTAssertTrue(
            element("elevation-chart", in: app)
                .waitForExistence(timeout: UITestTimeout.existence)
        )

        try audit(app)
    }

    @MainActor
    func testSettingsPassesAccessibilityAudit() throws {
        let app = launchApp()
        openSettings(in: app)

        try audit(app)
    }

    /// The recording screen is the one a hiker uses without looking at it, so
    /// its live numbers have to be readable and its phase has to be announced.
    @MainActor
    func testRecordingScreenIsReadable() throws {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let phase = element("recording-phase", in: app)
        XCTAssertTrue(
            phase.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertFalse(
            phase.label.isEmpty,
            "the phase dot is a colour, so the word beside it has to be spoken"
        )

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        XCTAssertEqual(points.label, "Points")
        XCTAssertNotNil(points.value as? String)

        try audit(app)
    }

    /// The review screen, which is the one place in the app where a decision
    /// is drawn as a tint and a checkmark.
    ///
    /// A choice that reads as two identical unnamed rows is unusable without
    /// sight, and this screen has no second way to tell them apart: the
    /// difference between them is the shape of a line on a map.
    @MainActor
    func testRouteReviewIsReadable() throws {
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
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        walkRecordedTrace(UITestFixture.reviewableTrace, countedBy: points)
        stopRecording(named: Self.reviewedHikeName, in: app)

        let title = element("review-section-title", in: app)
        XCTAssertTrue(
            title.waitForExistence(timeout: Self.reviewTimeout),
            "a snapped recording should stop in review"
        )
        XCTAssertFalse(
            title.label.isEmpty,
            "which stretch is being decided has to be said, not just drawn"
        )

        let keepTrail = element("review-choice-trail", in: app)
        let useGPS = element("review-choice-gps", in: app)
        XCTAssertTrue(keepTrail.waitForExistence(timeout: UITestTimeout.existence))
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

    /// The photo strip and the viewer it opens, seeded because the Simulator
    /// has no camera.
    ///
    /// A tile is a picture and nothing else, so its label is the only thing
    /// distinguishing one from the next; the viewer's toolbar is two glyphs,
    /// both destructive-adjacent, both unnamed without help.
    @MainActor
    func testPhotoGalleryIsReadable() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=2",
            ]
        )
        openHikeDetail(in: app)

        let strip = element("hike-photo-strip", in: app)
        XCTAssertTrue(
            scrollIntoView(strip, in: app),
            "a hike with photos should show the strip they live on"
        )
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Photo 1 of 2"))
            .firstMatch
        XCTAssertTrue(
            tile.waitForExistence(timeout: UITestTimeout.existence),
            "a tile should say which photo of how many it is"
        )
        try audit(app)

        tile.tap()
        XCTAssertTrue(
            element("photo-viewer", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertEqual(
            app.buttons["Delete photo"].label,
            "Delete photo",
            "a trash glyph is not a label"
        )
        XCTAssertEqual(
            app.buttons["Show where this photo was taken"].label,
            "Show where this photo was taken"
        )
        XCTAssertTrue(
            app.buttons["Next photo"].isEnabled,
            "the step buttons are disabled rather than hidden at the ends, so "
                + "with two photos the first one has somewhere to go"
        )

        try audit(app)
    }

    /// The empty state, which is a screen made almost entirely of glyphs
    /// interpolated into sentences.
    ///
    /// "Tap ⬇️ to import a GPX file" contributes nothing spoken where the
    /// symbol is, so each line carries a rewritten label naming the button it
    /// points at. This is also the only screen a first launch shows, which
    /// makes it the worst one to leave unreadable.
    @MainActor
    func testEmptyStateIsReadable() throws {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet"])

        let importPrompt = app.staticTexts[
            "Tap the Import GPX file button to import a GPX file."
        ]
        XCTAssertTrue(
            importPrompt.waitForExistence(timeout: UITestTimeout.existence),
            "the glyph in the sentence has to be spoken as the button it is"
        )
        XCTAssertTrue(
            app.staticTexts[
                "Or tap the Record a hike button to record one as you walk."
            ].exists
        )
        XCTAssertEqual(
            element("import-gpx-button", in: app).label,
            "Import GPX file",
            "and the button it names has to answer to that name"
        )
        XCTAssertEqual(
            element("record-hike-button", in: app).label,
            "Record a hike"
        )

        try audit(app)
    }

    /// Matching a trace against the bundled graph is real work on a cold
    /// simulator.
    private static let reviewTimeout: TimeInterval = 30
    private static let reviewedHikeName = "Reviewed Route"
}
