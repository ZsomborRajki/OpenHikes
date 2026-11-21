//
//  RecordingUITests+FollowTrails.swift
//  OpenHikesUITests
//
//  *Follow Trails* in *Edit Route*, asked of the router the app ships: a
//  walk recorded beside the bundled trail, a stretch of it picked out, and
//  the stretch drawn along the trail.
//
//  The other suites hold *Edit Route*'s steps against a router that answers
//  what it is told to, or against none. This one is the only place the trail
//  maker's own router is asked the editor's question, over the graph
//  `--ui-test-trail-graph` bundles, so a change to either that broke the
//  other would show here and nowhere else.
//

import CoreLocation
import XCTest

extension RecordingUITests {
    private static let followedHikeName = "Followed Route"
    private static let followTimeout: TimeInterval = 30

    @MainActor
    func testAStretchIsDrawnAlongTheMappedTrail() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph=\(UITestFixture.trailGraphName)",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.reviewableTrace[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        walkRecordedTrace(UITestFixture.reviewableTrace, countedBy: points)
        stopRecording(named: Self.followedHikeName, in: app)
        XCTAssertTrue(
            app.navigationBars[Self.followedHikeName].waitForExistence(timeout: Self.followTimeout),
            "the walk should be saved at once"
        )
        openEditRoute(in: app)

        scrollToTap(element("route-stretch-begin", in: app), in: app, attempts: 8)
        let follow = element("route-stretch-follow", in: app)
        XCTAssertTrue(follow.waitForExistence(timeout: UITestTimeout.existence))
        scrollToTap(follow, in: app, attempts: 8)

        XCTAssertTrue(
            element("route-step-undo", in: app).waitForExistence(timeout: Self.followTimeout),
            "the router should find the bundled trail between the two handles, and the stretch be drawn along it"
        )
        XCTAssertEqual(app.alerts.count, 0, "nothing was refused")
        XCTAssertTrue(waitUntil { element("route-trim-save", in: app).isEnabled })
    }
}
