//
//  OpenHikesUITests.swift
//  OpenHikesUITests
//
//  The functional half of this bundle: the app driven the way a hiker drives
//  it. Fixtures, launch helpers and location plumbing live in
//  ``UITestSupport``; accessibility-specific assertions live in
//  ``AccessibilityUITests``.
//

import CoreLocation
import XCTest

nonisolated final class OpenHikesUITests: XCTestCase {
    private static let reviewedHikeName = "Reviewed Route"

    @MainActor
    func testLaunchesMapAndOpensSettings() {
        let app = launchApp()

        XCTAssertTrue(
            element("trail-map", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(element("map-search", in: app).exists)

        element("settings-button", in: app).tap()
        XCTAssertTrue(
            app.navigationBars["Settings"]
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(element("settings-screen", in: app).exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    func testImportsBundledGPXAndOpensItsDetails() {
        let app = launchApp(
            arguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )

        openHikeDetail(in: app)
    }

    @MainActor
    func testSimulatedLocationStartsRecording() {
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

        setSimulatedLocation(
            CLLocationCoordinate2D(latitude: 47.718598, longitude: 12.831420)
        )
        let phase = element("recording-phase", in: app)
        XCTAssertTrue(
            phase.waitForExistence(timeout: UITestTimeout.navigation)
        )
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Recording"),
            evaluatedWith: phase
        )
        waitForExpectations(timeout: UITestTimeout.navigation)
    }

    /// The full recording round trip: walk a trace the matcher can snap onto a
    /// bundled trail, then decide in review which line the hike keeps.
    @MainActor
    func testReviewsSnappedRouteAfterStopping() {
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
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        walkRecordedTrace(UITestFixture.reviewableTrace, countedBy: points)
        stopRecording(in: app)

        XCTAssertTrue(
            element("review-section-title", in: app)
                .waitForExistence(timeout: Self.reviewTimeout),
            "a snapped recording should stop in review"
        )
        let keepTrail = element("review-choice-trail", in: app)
        let useGPS = element("review-choice-gps", in: app)
        XCTAssertTrue(keepTrail.exists)
        XCTAssertTrue(useGPS.exists)
        XCTAssertTrue(
            keepTrail.isSelected,
            "the matched trail is the standing choice"
        )

        scrollToTap(useGPS, in: app)
        XCTAssertTrue(
            waitUntilSelected(useGPS),
            "tapping a choice should move the checkmark to it"
        )
        XCTAssertFalse(keepTrail.isSelected)

        scrollToTap(element("review-save-hike", in: app), in: app)

        XCTAssertTrue(
            app.navigationBars[Self.reviewedHikeName]
                .waitForExistence(timeout: Self.saveTimeout),
            "the reviewed hike should be saved under the name it was given"
        )
    }

    /// A hike's line pattern is picked from five swatches that draw no text,
    /// and each is addressed by its own identifier — SwiftUI pushes a
    /// container's identifier down onto every descendant, which would leave
    /// all five answering to one name.
    @MainActor
    func testPicksARouteLinePattern() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        openHikeDetail(in: app)

        let directional = element("route-pattern-directional", in: app)
        let dotted = element("route-pattern-dotted", in: app)
        XCTAssertTrue(
            directional.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(
            directional.isSelected,
            "a hike starts on the line-with-arrows it has always been drawn as"
        )

        scrollToTap(dotted, in: app)
        XCTAssertTrue(
            waitUntilSelected(dotted),
            "tapping a swatch should move the selection to it"
        )
        XCTAssertFalse(directional.isSelected)
    }

    @MainActor
    func testLaunchPerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.launchIterations

        measure(
            metrics: [XCTApplicationLaunchMetric()],
            options: options
        ) {
            makeApp().launch()
        }
    }

    /// Matching a trace against the bundled graph is real work on a cold
    /// simulator, and saving writes the route plus its widget payload.
    private static let reviewTimeout: TimeInterval = 30
    private static let saveTimeout: TimeInterval = 20
    private static let launchIterations = 3

    @MainActor
    private func stopRecording(in app: XCUIApplication) {
        app.buttons["Stop"].tap()
        let namePrompt = app.alerts["Name Your Hike"]
        XCTAssertTrue(
            namePrompt.waitForExistence(timeout: UITestTimeout.navigation)
        )
        // The name is typed before the review opens, so saving it later also
        // proves the review step carries it through.
        let field = namePrompt.textFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: UITestTimeout.navigation)
        )
        field.tap()
        if let draft = field.value as? String, !draft.isEmpty {
            field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        }
        field.typeText(Self.reviewedHikeName)
        XCTAssertEqual(field.value as? String, Self.reviewedHikeName)
        namePrompt.buttons["Save"].tap()
    }
}
