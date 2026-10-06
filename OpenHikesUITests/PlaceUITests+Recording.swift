//
//  PlaceUITests+Recording.swift
//  OpenHikesUITests
//
//  *Add Place* while recording, for a place of the hiker's own: the sheet
//  hands the spot to the form a hike's screen adds places with, so the map
//  can put the place where it is — see ``RecordingPlaceSheet``.
//

import XCTest

extension PlaceUITests {
    @MainActor
    func testRecordingAddsAnOwnPlaceThroughTheMapForm() {
        let app = makeApp(arguments: ["--ui-test-enable-location"])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)
        // Handed over again until it is taken: the location set before launch
        // is older than the recording, and is refused as such.
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence),
            "the walk needs a fix before a place can be marked on it"
        )
        walkRecordedTrace([UITestFixture.trailheadCoordinate], countedBy: points)

        tapWhenReady(element("recording-add-place", in: app))
        scrollToTap(app.buttons["recording-place-add-own"], in: app)

        XCTAssertTrue(
            element("hike-place-adder-title", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "your own place opens the map form"
        )
        XCTAssertTrue(element("hike-place-placeholder", in: app).exists, "with its pin on the map")
        XCTAssertFalse(element("recording-place-sheet", in: app).exists, "and the sheet out of the map's way")

        app.buttons["hike-place-adder-add"].tap()
        let title = element("hike-place-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "adding opens the new place")
        XCTAssertEqual(title.label, "Viewpoint")
        popScreen(in: app)
        XCTAssertTrue(
            app.navigationBars["Record Hike"].waitForExistence(timeout: UITestTimeout.navigation),
            "back from the new place is the recording"
        )
    }
}
