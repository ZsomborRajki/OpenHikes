//
//  TrailMakerUITests.swift
//  OpenHikesUITests
//
//  Drawing a trail, from the pill on the map to a row in the library.
//
//  Nothing below this can reach it. The map is a `UIViewRepresentable` around
//  `MKMapView`, the pill is a UIKit subview positioned by a constraint the
//  sheet drives, and a tap that becomes a waypoint is resolved by a gesture
//  recognizer whose state and location the touch system sets — so the one
//  question this feature exists to answer, *does tapping the map put a point
//  down*, has no unit test and cannot have one.
//
//  What the suites next door cover instead: `TrailDraftTests` the arithmetic,
//  `TrailDraftSaveTests` the row that comes out, `TrailDraftControllerTests`
//  the two pills' exclusion and the guards, and
//  `MapCoordinatorTests+TrailDraft` the map's half with a real `MKMapView` and
//  a synthesised point. This is the one that presses the buttons.
//

import XCTest

nonisolated final class TrailMakerUITests: XCTestCase {
    /// What the drawn trail is named, and what the library row is found by.
    private static let trailName = "Saturday Ridge"

    /// Three taps well inside the map, spread far enough apart that no two of
    /// them land on the same coordinate at any plausible zoom.
    ///
    /// Normalized rather than absolute: the map fills the window, and the
    /// window is whatever device the runner resolved. The vertical range stays
    /// in the top half, clear of the sheet at every detent it can rest at and
    /// clear of the controls on the leading edge.
    private static let drawnPoints: [CGVector] = [
        CGVector(dx: 0.45, dy: 0.20),
        CGVector(dx: 0.65, dy: 0.30),
        CGVector(dx: 0.50, dy: 0.42),
    ]

    /// The whole feature end to end: open the maker from the map, put three
    /// points down, save, and find the trail in the library.
    @MainActor
    func testDrawingATrailSavesItToTheLibrary() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(
            map.waitForExistence(timeout: UITestTimeout.navigation),
            "the map should be up before anything is drawn"
        )

        openTheMaker(in: app)

        // Nothing is down yet, and the screen says what to do about it.
        XCTAssertTrue(
            element("trail-draft-empty", in: app).exists,
            "an empty maker should say how to start"
        )
        let save = element("trail-draft-save", in: app)
        XCTAssertFalse(
            save.isEnabled,
            "a trail with no points cannot be saved"
        )

        draw(Self.drawnPoints, on: map, in: app)

        // Three points, in the order they went down, with the running length
        // on the header beside them.
        XCTAssertTrue(
            element("trail-draft-point-3", in: app).exists,
            "the third point should be listed"
        )
        XCTAssertTrue(
            element("trail-draft-length", in: app).exists,
            "the maker should show how long the line is so far"
        )
        XCTAssertTrue(save.isEnabled, "three points is a trail")

        // Named on the way out, in the alert Save opens — the same shape a
        // stopped recording is named in, and the only place the maker asks.
        save.tap()
        nameTheTrail(Self.trailName, in: app)

        // A saved trail lands exactly where a stopped recording lands: on its
        // own screen, over a map drawing it.
        XCTAssertTrue(
            app.navigationBars[Self.trailName].waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "saving should open the trail it just made"
        )

        // And it is in the library, which is the claim that matters: a drawn
        // trail is an ordinary hike from here on, reachable the way every
        // other hike is.
        popScreen(in: app)
        awaitHikeRow(titled: Self.trailName, in: app)
    }

    /// Cancel throws the drawing away and says so first. The confirmation is
    /// what makes the button safe to put next to Save.
    @MainActor
    func testCancellingDiscardsTheDrawing() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTheMaker(in: app)
        draw(Array(Self.drawnPoints.prefix(2)), on: map, in: app)

        element("trail-draft-cancel", in: app).tap()
        let discard = app.buttons["Discard"]
        XCTAssertTrue(
            discard.waitForExistence(timeout: UITestTimeout.navigation),
            "cancelling a drawing should ask before throwing it away"
        )
        discard.tap()

        XCTAssertTrue(
            waitUntil { element("map-sheet", in: app).exists },
            "cancelling should land back on the map"
        )

        // And nothing was kept: reopening the maker starts from nothing.
        openTheMaker(in: app)
        XCTAssertTrue(
            element("trail-draft-empty", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "a discarded drawing should not come back"
        )
    }

    /// The pill takes the slot the camera pill is in, and the two are offered
    /// on opposite signals — so the search screen has one and a hike's screen
    /// has the other, never both.
    @MainActor
    func testTheMakerAndCameraPillsTakeTurns() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        let maker = element("map-trail-maker-button", in: app)
        let camera = element("map-camera-button", in: app)

        XCTAssertTrue(
            maker.waitForExistence(timeout: UITestTimeout.existence),
            "the search screen offers the maker"
        )
        XCTAssertFalse(camera.exists, "and not the camera, which has nothing to file into")

        // A hike's own screen is the camera's half of the arrangement.
        openHikeDetail(in: app)
        XCTAssertTrue(
            camera.waitForExistence(timeout: UITestTimeout.existence),
            "a pushed hike offers the camera"
        )
        // Waited on rather than asserted outright: the pill leaves on a fade,
        // and it is still in the hierarchy for the quarter-second that takes.
        XCTAssertTrue(
            waitUntil { !maker.exists },
            "the maker should give up the slot it shares with the camera"
        )

        popScreen(in: app)
        XCTAssertTrue(
            waitUntil { maker.exists && !camera.exists },
            "backing out should hand the slot back"
        )
    }

    // MARK: - Helpers

    /// Opens the maker from the map's own pill, which is the only way in.
    @MainActor
    private func openTheMaker(in app: XCUIApplication) {
        let pill = element("map-trail-maker-button", in: app)
        XCTAssertTrue(
            pill.waitForExistence(timeout: UITestTimeout.existence),
            "the search screen should offer to make a trail"
        )
        pill.tap()
        XCTAssertTrue(
            element("trail-draft-save", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "tapping the pill should open the maker"
        )
    }

    /// Answers the alert Save opens, which is the only place the maker asks
    /// what the trail is called.
    ///
    /// The field opens blank — the placeholder is the default name — so this
    /// types rather than replaces, unlike `stopRecording(named:in:)` next
    /// door.
    @MainActor
    private func nameTheTrail(_ name: String, in app: XCUIApplication) {
        let prompt = app.alerts["Name Your Trail"]
        XCTAssertTrue(
            prompt.waitForExistence(timeout: UITestTimeout.navigation),
            "saving should ask what the trail is called"
        )
        let field = prompt.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UITestTimeout.navigation))
        field.tap()
        field.typeText(name)
        prompt.buttons["Save"].tap()
    }

    /// Taps the map at each offset and waits for the point to be listed.
    ///
    /// Waiting on the row rather than tapping three times and asserting once:
    /// a tap that missed is indistinguishable from one the app has not
    /// processed yet, and only the wait tells them apart. No fixed sleep —
    /// each point is its own effect to wait on.
    @MainActor
    private func draw(_ offsets: [CGVector], on map: XCUIElement, in app: XCUIApplication) {
        for (index, offset) in offsets.enumerated() {
            map.coordinate(withNormalizedOffset: offset).tap()
            let row = element("trail-draft-point-\(index + 1)", in: app)
            XCTAssertTrue(
                row.waitForExistence(timeout: UITestTimeout.navigation),
                "tapping the map should put point \(index + 1) down"
            )
        }
    }
}
