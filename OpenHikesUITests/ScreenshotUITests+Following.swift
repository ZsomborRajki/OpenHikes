//
//  ScreenshotUITests+Following.swift
//  OpenHikesUITests
//
//  App Store frame 04, a trail followed from where the hiker is standing, in
//  a file of its own for the reason frames 08 and 09 have one:
//  `ScreenshotUITests.swift` is at the length the linter allows, and an
//  extension keeps it inside the one suite `Scripts/screenshots.sh` runs.
//

import CoreLocation
import XCTest

extension ScreenshotUITests {
    /// A point of the fixture's own line, 5.9 km of its 10.7: past the alm,
    /// out along the top of the Rinnkendlsteig. On the line rather than near
    /// it, so the match is the walk's and not a guess.
    private static let partWayLatitude = 47.567725
    private static let partWayLongitude = 12.963823
    private static let partWayAlong = CLLocationCoordinate2D(latitude: partWayLatitude, longitude: partWayLongitude)

    /// Where on the walk the hiker is, and how much of it is left — the
    /// question a phone comes out of a pocket for.
    ///
    /// The detail screen with a position on the trail: the map draws the
    /// hiker on the line, the chart's tracker stands where they are, and the
    /// card under it reads *Live Progress* with the share walked and the
    /// distance left. Shot without a position this was the same screen with
    /// that card reading a grey 0% under a chart pointing at the car park,
    /// and it said nothing *Following* does.
    ///
    /// A single fix, so no walk starts — that takes the hiker moving along
    /// the line — and the card is the follow's, not a walk's.
    @MainActor
    func testCapturesFollowingTheTrail() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-weather",
            Self.routeHueArgument,
        ])
        // No `resetAuthorizationStatus`: the script grants location before the
        // run, so no prompt lands on this frame's first gesture. The monitor
        // stays for a run started some other way.
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.partWayAlong)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        openHikeDetail(in: app, titled: Self.routeTitle)
        let progress = element("trail-progress", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { progress.label == "Live Progress" },
            "following should match the hiker onto the line — the card said \"\(progress.label)\""
        )
        XCTAssertTrue(
            scrollIntoView(element("elevation-chart", in: app), in: app),
            "the hike should draw its elevation chart"
        )
        capture(as: .following)
    }
}
