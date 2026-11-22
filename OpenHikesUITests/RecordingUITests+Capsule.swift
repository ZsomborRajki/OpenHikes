//
//  RecordingUITests+Capsule.swift
//  OpenHikesUITests
//
//  The map's activity capsule while a recording is under way away from its
//  own screen: absent on that screen, there on the map once it is left, and
//  doing what the recording screen's bar does — Pause turns into Resume, Stop
//  asks the bar's question, and the status goes back to the recording. See
//  ``MapActivityCapsule``.
//
//  Worth a test of its own because the capsule can be on screen and still
//  missing here: MapKit leaves SwiftUI hosted on the map out of the
//  accessibility tree, which is why its buttons are UIKit — see
//  ``MapActivityCapsuleControlsView``.
//

import XCTest

extension RecordingUITests {
    @MainActor
    func testTheMapCapsuleControlsARecordingAwayFromItsScreen() {
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

        let status = element("activity-capsule-status", in: app)
        XCTAssertFalse(status.exists, "the recording's own bar holds its controls on its screen")

        popScreen(in: app)
        XCTAssertTrue(
            status.waitForExistence(timeout: UITestTimeout.navigation),
            "leaving the recording's screen should put its controls on the map"
        )

        let pause = element("activity-capsule-pause", in: app)
        tapWhenReady(pause)
        expectLabel(pause, contains: "Resume")

        tapWhenReady(element("activity-capsule-stop", in: app))
        let prompt = app.alerts["Name Your Hike"]
        XCTAssertTrue(
            prompt.waitForExistence(timeout: UITestTimeout.navigation),
            "the capsule's Stop should ask what the bar's Stop asks"
        )
        prompt.buttons["Keep Recording"].tap()

        tapWhenReady(status)
        XCTAssertTrue(
            app.navigationBars["Record Hike"].waitForExistence(timeout: UITestTimeout.navigation),
            "the status should go back to the recording"
        )
    }
}
