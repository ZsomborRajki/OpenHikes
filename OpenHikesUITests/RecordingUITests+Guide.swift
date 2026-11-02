//
//  RecordingUITests+Guide.swift
//  OpenHikesUITests
//
//  A trail of the hiker's own, shown under a recording under way: chosen on
//  the trail's own screen, named on the recording screen, and taken away
//  again from there.
//
//  The line itself is MapKit's pixels and not in the accessibility tree, so
//  what this asserts is what a hiker reaches through the screens; the line is
//  the unit suites' (`RecordingGuideTests`,
//  `MapCoordinatorTests+RecordingGuide`). It is here as much for
//  `Scripts/render-trace.sh` as for the check: choosing the trail draws a line
//  under a live recording and leaves the sheet, and a change that lets either
//  re-run SwiftUI shows up in this test's steps —
//  `render-trace.sh --suite RecordingUITests --test testShowingATrailUnderARecording`.
//

import CoreLocation
import XCTest

extension RecordingUITests {
    /// The walk up the Rinnkendlsteig the seeded recording holds — see
    /// `SeededRecordingFixture` — and where the walker stands on it, a few
    /// metres past its last point, so the recovered recording takes the fix as
    /// its next step.
    private static let recordingFixture = "KoenigsseeRinnkendlsteig"
    private static let walkerLatitude = 47.578153
    private static let walkerLongitude = 12.968470
    private static let walker = CLLocationCoordinate2D(latitude: walkerLatitude, longitude: walkerLongitude)
    /// One of `--ui-test-seed-nearby-trails`' trails, over the same valley.
    private static let guideTitle = "Gotzenalm"

    @MainActor
    func testShowingATrailUnderARecording() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-seed-nearby-trails",
            "--ui-test-seed-recording=\(Self.recordingFixture)",
        ])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.walker)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        let recordButton = element("record-hike-button", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { recordButton.label == "Open hike recording" },
            "the seeded recording should have been recovered and resumed"
        )

        openHikeDetail(in: app, titled: Self.guideTitle)
        let toggle = element("recording-guide-toggle", in: app)
        XCTAssertTrue(
            toggle.waitForExistence(timeout: UITestTimeout.existence),
            "a trail's screen offers to show it while a recording is under way"
        )
        XCTAssertEqual(toggle.label, "Show While Recording")
        toggle.tap()

        XCTAssertTrue(
            app.navigationBars["Record Hike"].waitForExistence(timeout: UITestTimeout.navigation),
            "showing the trail goes to the recording it is shown under"
        )
        let guide = element("recording-guide", in: app)
        XCTAssertTrue(guide.waitForExistence(timeout: UITestTimeout.existence), "the recording names the trail")
        XCTAssertEqual(guide.label, "Trail on the Map")
        XCTAssertEqual(guide.value as? String, Self.guideTitle)

        tapWhenReady(element("recording-guide-stop", in: app))
        XCTAssertTrue(
            guide.waitForNonExistence(timeout: UITestTimeout.existence),
            "Stop Showing takes the trail off the recording"
        )
    }
}
