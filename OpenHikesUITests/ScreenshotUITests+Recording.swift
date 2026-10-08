//
//  ScreenshotUITests+Recording.swift
//  OpenHikesUITests
//
//  App Store frame 05, a recording under way, in a file of its own for the
//  reason frames 08 and 09 have one: `ScreenshotUITests.swift` is at the
//  length the linter allows, and an extension keeps it inside the one suite
//  `Scripts/screenshots.sh` runs.
//

import CoreLocation
import XCTest

extension ScreenshotUITests {
    /// Where the walker is when the frame is shot: a few metres on from the
    /// last point the seeded recording holds, along the fixture's own line,
    /// at its height. Close enough to the last point that the recorder takes
    /// it as the next step of the same walk.
    private static let walkerLatitude = 47.578153
    private static let walkerLongitude = 12.968470
    private static let walkerCoordinate = CLLocationCoordinate2D(latitude: walkerLatitude, longitude: walkerLongitude)
    private static let walkerAltitude: CLLocationDistance = 1322

    /// How far up the frame drags its map, as a share of the screen, to bring
    /// the walker and the fresh end of the line out from under the sheet.
    private static let recordingLift: CGFloat = 0.2
    /// Where the drag starts: clear of the walker, the weather badge and the
    /// map's controls.
    private static let liftAnchorX: CGFloat = 0.7
    private static let liftAnchorY: CGFloat = 0.34
    /// Long enough for the drag to be taken as a drag rather than a tap.
    private static let liftPressDuration = 0.1
    /// Fewer points than the seeded stretch holds, so a count above it means
    /// the recording on screen is the recovered one rather than a new one.
    private static let recoveredPointFloor = 100

    /// A recording two hours in, half way up the climb to the alm.
    ///
    /// The figures are the whole point of the screen, so the recording is a
    /// real one rather than one just started: `--ui-test-seed-recording`
    /// leaves the journal of the walk's first four kilometres, with the
    /// file's own clock and heights, and the recorder's recovery resumes it —
    /// see `SeededRecordingFixture`. The frame used to walk twenty fixes in
    /// here, 22 m apart every four seconds, and read 18 km/h, no climb, and a
    /// line along a village street.
    ///
    /// The record button is what opens it, as it opens a recording for a
    /// hiker — and is waited on until it says so, because tapped while the
    /// recovery is still under way it would start a second recording.
    @MainActor
    func testCapturesRecordingAHike() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-weather",
            "--ui-test-seed-recording=\(Self.routeFixture)",
            Self.routeHueArgument,
        ])
        // No `resetAuthorizationStatus`: the script grants location before the
        // run, so no prompt lands on this frame's first gesture. The monitor
        // stays for a run started some other way.
        addLocationPermissionMonitor()
        XCUIDevice.shared.location = XCUILocation(
            location: CLLocation(
                coordinate: Self.walkerCoordinate,
                altitude: Self.walkerAltitude,
                horizontalAccuracy: UITestFixture.simulatedAccuracy,
                verticalAccuracy: UITestFixture.simulatedAccuracy,
                timestamp: .now
            )
        )
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        let recordButton = element("record-hike-button", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { recordButton.label == "Open hike recording" },
            "the seeded recording should have been recovered and resumed"
        )
        recordButton.tap()
        XCTAssertTrue(
            app.navigationBars["Record Hike"].waitForExistence(timeout: UITestTimeout.navigation),
            "the record button should open the recording under way"
        )
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) {
                (Int(points.value as? String ?? "") ?? 0) > Self.recoveredPointFloor
            },
            "the recording screen should be the recovered walk's"
        )
        // The recovery says so, truthfully, in an orange card over the
        // figures. A hiker closes it once; the frame is of the screen after.
        let notice = element("recording-recovery-dismiss", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: UITestTimeout.existence), "a resumed recording says so")
        notice.tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: UITestTimeout.existence), "and closes when asked")
        liftRecordedLineClearOfTheSheet(in: app)
        capture(as: .recording)
    }

    /// Drags the map up so the walker and the line behind them sit in the
    /// band the sheet is not over.
    ///
    /// A fixed pan, unlike every other framing gesture in the set, and not for
    /// want of trying: the recorded line is an `MKPolyline`, which is drawn
    /// rather than exposed, so there is no element to measure and nothing to
    /// correct against. What is known is the geometry — the recording map
    /// keeps the walker at the *window's* centre, which is behind a sheet
    /// resting at its middle detent, so the freshest end of the line is the
    /// part a reader cannot see.
    @MainActor
    private func liftRecordedLineClearOfTheSheet(in app: XCUIApplication) {
        let map = mapElement(in: app)
        map.coordinate(withNormalizedOffset: CGVector(dx: Self.liftAnchorX, dy: Self.liftAnchorY))
            .press(
                forDuration: Self.liftPressDuration,
                thenDragTo: map.coordinate(
                    withNormalizedOffset: CGVector(dx: Self.liftAnchorX, dy: Self.liftAnchorY - Self.recordingLift)
                )
            )
    }
}
