//
//  AccessibilityUITests+Recording.swift
//  OpenHikesUITests
//
//  The recording screen, swept with the live figures it is read by. Moved out
//  of `AccessibilityUITests.swift` when checking the spoken average took the
//  class past SwiftLint's `type_body_length`.
//
//  Not a second test class, for the reason `AccessibilityUITests+Presented`
//  gives: these are `AccessibilityUITests` methods, they run in the
//  `accessibility-ui-tests` job with the rest, and `--suite
//  AccessibilityUITests` still selects them.
//

import XCTest

extension AccessibilityUITests {
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

        // Captioned "Avg Speed", which a voice would have to guess at, and
        // spoken in full, as the watch and the widget's chip speak it. The
        // drawn caption is still in the tree, as a child XCUI lists and
        // VoiceOver does not stop on, so only the row itself is asked about.
        let averageSpeed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Average Speed"))
            .firstMatch
        XCTAssertTrue(
            averageSpeed.waitForExistence(timeout: UITestTimeout.existence),
            "the live average should be spoken in full"
        )
        XCTAssertNotNil(averageSpeed.value as? String, "with its speed, or the dash before one, as the value")

        try audit(app)
    }
}
