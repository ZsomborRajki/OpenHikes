//
//  WalkUITests+Offer.swift
//  OpenHikesUITests
//
//  The two answers to the walk offer that are not Start: Ignore, which
//  leaves Start on screen while the hiker is on the trail, and Don't Ask
//  Again, which turns the trail's own switch off. The notification half of
//  the offer is unreachable from here — reminders are not composed under UI
//  testing, because a permission prompt is a system alert no run can tap
//  past — and is pinned by the unit suites instead.
//

import XCTest

extension WalkUITests {
    /// Ignore stops asking but leaves Start on screen while the hiker is on
    /// the trail — "not now" is not "not possible".
    @MainActor
    func testIgnoringTheOfferLeavesStartAvailable() {
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
        let offer = element("walk-offer", in: app)
        XCTAssertTrue(offer.waitForExistence(timeout: UITestTimeout.trace))

        scrollToTap(element("walk-offer-ignore", in: app), in: app)

        XCTAssertTrue(offer.waitForNonExistence(timeout: UITestTimeout.navigation))
        acceptWalkOffer(in: app)
        let phase = element("walk-phase", in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.navigation))
        expectPhase(phase, contains: "Active")
    }

    /// Don't Ask Again turns the trail's own switch off, and the switch is
    /// the way back.
    @MainActor
    func testDontAskAgainTurnsTheTrailsSwitchOff() {
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
        let offer = element("walk-offer", in: app)
        XCTAssertTrue(offer.waitForExistence(timeout: UITestTimeout.trace))

        scrollToTap(element("walk-offer-never", in: app), in: app)

        XCTAssertTrue(offer.waitForNonExistence(timeout: UITestTimeout.navigation))
        let asks = app.switches["walk-offer-toggle"]
        XCTAssertTrue(scrollUntilVisible(asks, in: app))
        XCTAssertEqual(asks.value as? String, "0")
        XCTAssertTrue(
            element("walk-offer-start", in: app).exists,
            "silencing the question must not take Start away"
        )

        scrollToTap(asks, in: app)
        XCTAssertEqual(asks.value as? String, "1")
        // The next match asks again.
        setSimulatedLocation(UITestFixture.trailPoints[1])
        XCTAssertTrue(offer.waitForExistence(timeout: UITestTimeout.trace))
    }
}
