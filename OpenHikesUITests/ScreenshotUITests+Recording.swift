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

    /// Fewer points than the seeded stretch holds, so a count above it means
    /// the recording on screen is the recovered one rather than a new one.
    private static let recoveredPointFloor = 100
    private static let recordingFrameMargin: CGFloat = 0.07
    private static let recordingPanPress: TimeInterval = 0.1

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
        frameRecordedLine(in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { screenshotMapHasTiles(in: app) },
            "the map should finish drawing its terrain after zooming"
        )
        capture(as: .recording, of: app)
    }

    /// Fits the red stroke into the map above the measured sheet. Collapsing
    /// it temporarily exposes the map's center for two-finger zoom-out taps;
    /// the original detent is restored before the capture.
    @MainActor
    private func frameRecordedLine(in app: XCUIApplication) {
        let map = mapElement(in: app)
        let window = windowFrame(of: app)
        let original = openMapArea(in: app)
        let panel = element("map-side-panel", in: app).exists
        let margin = original.width * Self.recordingFrameMargin
        let weather = element("weather-badge", in: app)
        let top = max(original.minY + margin, weather.exists ? weather.frame.maxY + margin : original.minY)
        let target = CGRect(
            x: original.minX + margin,
            y: top,
            width: original.width - margin * 2,
            height: original.maxY - top - margin
        )
        collapseSheet(in: app)
        defer {
            if !panel { dragSheet(in: app, to: (original.maxY - window.minY) / window.height) }
        }
        let visible = openMapArea(in: app).insetBy(dx: 2, dy: 2)
        for _ in 0..<10 {
            guard let bounds = recordedLineBounds(in: app, within: visible) else {
                XCTFail("the recovered recording should draw a red line on the map")
                return
            }
            if target.contains(bounds) { return }
            let clipped = !visible.insetBy(dx: margin, dy: margin).contains(bounds)
            if clipped || bounds.width > target.width || bounds.height > target.height {
                zoomRecordingMapOut(in: app)
            } else {
                let anchor = CGPoint(x: visible.maxX - margin, y: visible.midY)
                let landing = CGPoint(
                    x: anchor.x + target.midX - bounds.midX,
                    y: anchor.y + target.midY - bounds.midY
                )
                coordinate(at: anchor, on: map).press(
                    forDuration: Self.recordingPanPress,
                    thenDragTo: coordinate(at: landing, on: map)
                )
            }
        }
        XCTFail("the recording’s line should fit above the sheet before capture")
    }
}
