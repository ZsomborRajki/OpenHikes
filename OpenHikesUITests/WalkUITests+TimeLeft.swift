//
//  WalkUITests+TimeLeft.swift
//  OpenHikesUITests
//
//  The walk's time left on the map, standing on the trail's own line — see
//  `MapCoordinator+WalkTimeLeft.swift`. Split from `WalkUITests.swift` for
//  the class body's length.
//

import CoreLocation
import XCTest

extension WalkUITests {
    /// The walk's time left stands on the trail's own line, halfway along
    /// what is still to walk, and speaks as a time left — see
    /// `MapCoordinator+WalkTimeLeft.swift`. Started by hand at the trailhead,
    /// so the fixes along the trail are what put it there.
    @MainActor
    func testTheTimeLeftStandsOnTheTrailAhead() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
        ])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailPoints[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        openHikeDetail(in: app)
        _ = startWalkByHand(in: app)
        let bubble = element("walk-time-left", in: app)
        // Paced, as the follow steps elsewhere here are, to outlast the
        // location manager's one publish a second.
        for point in UITestFixture.trailPoints[1...2] {
            Thread.sleep(forTimeInterval: UITestFixture.paceSeconds)
            setSimulatedLocation(point)
        }

        XCTAssertTrue(bubble.waitForExistence(timeout: UITestTimeout.trace), "the map shows no time left")
        XCTAssertTrue(bubble.label.hasSuffix("left"), "the bubble speaks as a time left: \(bubble.label)")
    }
}
