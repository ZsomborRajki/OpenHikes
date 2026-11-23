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
        // A line, so that Stop asks for its name rather than ending a walk
        // with nothing in it.
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        walkRecordedTrace(Array(UITestFixture.trailPoints.prefix(2)), countedBy: points)

        let status = element("activity-capsule-status", in: app)
        // Waited on: the capsule can come up for the moment between the
        // recording starting and its screen arriving.
        XCTAssertTrue(
            waitUntil { !status.exists },
            "the recording's own bar holds its controls on its screen"
        )

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

    /// The capsule's Stop can be tapped with one of the walk's own screens
    /// over the recording's, and throwing the walk away takes that screen
    /// with the draft it was about, rather than leaving it showing a deleted
    /// hike. One fix and one place: Stop asks before the place goes.
    @MainActor
    func testDiscardingFromTheCapsuleClosesTheWalksOwnScreens() {
        let app = makeApp(arguments: ["--ui-test-enable-location"])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }
        launch(app)
        startRecording(in: app)
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence),
            "the walk needs a fix before a place can be marked on it"
        )
        walkRecordedTrace([UITestFixture.trailheadCoordinate], countedBy: points)

        openRecordingPlaces(in: app)
        scrollToTap(app.buttons["recording-place-add-own"], in: app)
        tapWhenReady(app.buttons["hike-place-adder-add"])
        let place = element("hike-place-title", in: app)
        XCTAssertTrue(
            place.waitForExistence(timeout: UITestTimeout.navigation),
            "adding opens the new place over the recording"
        )

        tapWhenReady(element("activity-capsule-stop", in: app))
        let question = app.alerts["Discard this recording?"]
        XCTAssertTrue(
            question.waitForExistence(timeout: UITestTimeout.navigation),
            "a walk with no line but a place should be asked before the place goes"
        )
        question.buttons["Discard Recording"].tap()

        XCTAssertTrue(
            place.waitForNonExistence(timeout: UITestTimeout.navigation),
            "the discarded walk's place should leave with it"
        )
    }
}
