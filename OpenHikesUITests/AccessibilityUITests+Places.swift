//
//  AccessibilityUITests+Places.swift
//  OpenHikesUITests
//
//  The screens a saved hike's places open, which #651 and #652 added and no
//  sweep had seen (#662).
//
//  They are the densest forms the app has added since the community share
//  form: a kind picker, a multi-line note, a photo strip with its own buttons,
//  and a results list whose every row carries its own add button. That
//  is where hit-area (#535) and unlabelled-glyph failures have turned up
//  before, and every one of these screens was already driven by `PlaceUITests`
//  — which does not run in CI — so each had working automation and nothing
//  that gates a merge.
//
//  Not a second test class, for the reason `AccessibilityUITests+Presented`
//  gives: these are `AccessibilityUITests` methods, they run in the
//  `accessibility-ui-tests` job with the rest, and `--suite
//  AccessibilityUITests` still selects them.
//
//  Two of them need OpenStreetMap to answer, and a launch running tests has no
//  source to ask — see ``SeededTrailPointSource``, which is what
//  `--ui-test-trail-points=` names.
//

import XCTest

extension AccessibilityUITests {
    /// A place's own screen, once for each kind of place a hike holds.
    ///
    /// Both in one test because the two are different screens drawn by one
    /// view: the hiker's own place has a note and an *Edit* button, and
    /// OpenStreetMap's has neither but links to where it is corrected.
    @MainActor
    func testHikePlaceScreenPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(PlaceFixture.gpxName)"])
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)

        openPlace(named: PlaceFixture.ownPlace, in: app)
        XCTAssertTrue(
            element("hike-place-camera", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the audit is worth nothing against a screen that has not drawn yet"
        )
        try audit(app)

        popScreen(in: app)
        openPlace(named: PlaceFixture.mappedPlace, in: app)
        XCTAssertTrue(element("hike-place-camera", in: app).waitForExistence(timeout: UITestTimeout.existence))
        try audit(app)
    }

    /// Editing the hiker's own place: a name, a kind picker and a note.
    @MainActor
    func testHikePlaceEditorPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(PlaceFixture.gpxName)"])
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        openPlace(named: PlaceFixture.ownPlace, in: app)

        tapWhenReady(app.buttons["hike-place-edit"])
        XCTAssertTrue(
            element("hike-place-note-field", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the editor should have drawn before it is swept"
        )

        try audit(app)
    }

    /// *Add Place* from the map's pill, with its placeholder pin on the map
    /// behind it.
    ///
    /// Swept without staged photographs: the camera is unavailable on the
    /// Simulator and the library picker is a system process, so the strip's
    /// tiles and their remove buttons are the one part of this form automation
    /// cannot reach.
    @MainActor
    func testHikePlaceAdderPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(PlaceFixture.gpxName)"])
        openPlaceAdder(in: app)
        XCTAssertTrue(
            element("hike-place-adder-library", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the form should have drawn before it is swept"
        )

        try audit(app)
    }

    /// *Places Around Trail*, answered: the kind chips, *Within*, a list whose
    /// rows each carry an add button, and the pale pins on the map — then the
    /// card a found place opens.
    @MainActor
    func testPlacesAroundPassesAccessibilityAudit() throws {
        let app = openPlacesAround(scenario: "seeded")
        XCTAssertTrue(
            element("places-around-nearby", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the search should have answered before it is swept"
        )
        let add = app.buttons["Add Lakeshore Hut"]
        XCTAssertTrue(add.exists, "a found place's add button says which place it adds")
        XCTAssertTrue(
            app.buttons["trail-place-kind-Summit"].isSelected,
            "a kind switched on is a selected chip, and the fill is decoration — the trait is what says so"
        )

        try audit(app)

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thumsee Kopf")).firstMatch
        scrollToTap(row, in: app)
        XCTAssertTrue(
            element("places-around-card-add", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a found place's row opens its card"
        )
        try audit(app)
    }

    /// *Places Around Trail*, refused: the copy a hiker reads when
    /// OpenStreetMap cannot be reached, which nothing could put on screen
    /// before ``SeededTrailPointSource``.
    @MainActor
    func testRefusedPlacesAroundPassesAccessibilityAudit() throws {
        let app = openPlacesAround(scenario: "refused")
        XCTAssertTrue(
            app.buttons["Try Again"].waitForExistence(timeout: UITestTimeout.navigation),
            "a refused search should say so and offer to ask again"
        )

        try audit(app)
    }

    /// *Add Place* while recording: what OpenStreetMap has where the hiker
    /// stands, then a place of their own.
    @MainActor
    func testRecordingPlaceSheetPassesAccessibilityAudit() throws {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-points=seeded",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)
        // A place is marked at the last accepted fix, and *Add Place* before
        // the first one is an alert rather than the sheet.
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                points.exists && (points.value as? String).map { $0 != "0" } == true
            },
            "the walk needs a fix before a place can be marked on it"
        )

        tapWhenReady(element("recording-add-place", in: app))
        XCTAssertTrue(
            element("recording-place-suggestion", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "what is mapped at the trailhead should be offered before it is swept"
        )

        try audit(app)
    }

    /// Opens the fixture hike's *Places Around Trail* against the named
    /// stand-in.
    @MainActor
    private func openPlacesAround(scenario: String) -> XCUIApplication {
        let app = launchApp(
            arguments: [
                "--ui-test-import-gpx=\(PlaceFixture.gpxName)",
                "--ui-test-trail-points=\(scenario)",
            ]
        )
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        scrollToTap(element("hike-place-search", in: app), in: app)
        return app
    }
}
