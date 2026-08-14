//
//  OpenTrailsUITests.swift
//  OpenTrailsUITests
//

import CoreLocation
import XCTest

nonisolated final class OpenTrailsUITests: XCTestCase {
    private static let importedHikeTitle =
        "Thumsee Loop (fast, simulated)"

    /// Mirrors `UITestRecordingFixture` in `OpenTrailsTests`, which asserts
    /// that this trace still snaps onto the bundled graph and produces exactly
    /// one reviewable section. The numbers are duplicated because this bundle
    /// runs out-of-process and cannot import the app.
    private static let trailGraphFixture = "ThumseeRidgePath"
    private static let reviewedHikeName = "Reviewed Route"
    /// Slow enough that a 22 m step reads as a walk rather than a sprint the
    /// recorder would reject.
    private static let paceSeconds: TimeInterval = 4
    private static let recordedTrace = [
        CLLocationCoordinate2D(latitude: 47.71840, longitude: 12.83180),
        CLLocationCoordinate2D(latitude: 47.71860, longitude: 12.83180),
        CLLocationCoordinate2D(latitude: 47.71880, longitude: 12.83180),
    ]

    @MainActor
    func testLaunchesMapAndOpensSettings() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(
            element("trail-map", in: app).waitForExistence(timeout: 10)
        )
        XCTAssertTrue(element("map-search", in: app).exists)

        element("settings-button", in: app).tap()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(element("settings-screen", in: app).exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    func testImportsBundledGPXAndOpensItsDetails() {
        let app = makeApp(
            arguments: ["--ui-test-import-gpx=ThumseeLoopFast"]
        )
        app.launch()

        let hikeTitle = app.staticTexts[Self.importedHikeTitle]
        XCTAssertTrue(hikeTitle.waitForExistence(timeout: 15))
        hikeTitle.tap()

        XCTAssertTrue(
            app.navigationBars[Self.importedHikeTitle]
                .waitForExistence(timeout: 5)
        )
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
        setSimulatedLocation(latitude: 47.718420, longitude: 12.831774)
        defer { XCUIDevice.shared.location = nil }

        app.launch()
        app.tap()

        let recordButton = element("record-hike-button", in: app)
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10))
        recordButton.tap()
        XCTAssertTrue(
            app.navigationBars["Record Hike"].waitForExistence(timeout: 5)
        )

        setSimulatedLocation(latitude: 47.718598, longitude: 12.831420)
        let phase = element("recording-phase", in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Recording"),
            evaluatedWith: phase
        )
        waitForExpectations(timeout: 10)
    }

    /// The full recording round trip: walk a trace the matcher can snap onto a
    /// bundled trail, then decide in review which line the hike keeps.
    @MainActor
    func testReviewsSnappedRouteAfterStopping() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph=\(Self.trailGraphFixture)",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.recordedTrace[0])
        defer { XCUIDevice.shared.location = nil }

        app.launch()
        app.tap()

        let recordButton = element("record-hike-button", in: app)
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10))
        recordButton.tap()
        XCTAssertTrue(
            app.navigationBars["Record Hike"].waitForExistence(timeout: 5)
        )

        walkRecordedTrace(in: app)
        stopRecording(in: app)

        XCTAssertTrue(
            element("review-section-title", in: app)
                .waitForExistence(timeout: 30),
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

        tap(useGPS, in: app)
        XCTAssertTrue(
            waitUntilSelected(useGPS),
            "tapping a choice should move the checkmark to it"
        )
        XCTAssertFalse(keepTrail.isSelected)

        tap(element("review-save-hike", in: app), in: app)

        XCTAssertTrue(
            app.navigationBars[Self.reviewedHikeName]
                .waitForExistence(timeout: 20),
            "the reviewed hike should be saved under the name it was given"
        )
    }

    /// A hike's line pattern is picked from five swatches that carry no text,
    /// so their accessibility identifiers are the only thing that tells them
    /// apart — and SwiftUI pushes a container's identifier down onto every
    /// descendant, which would leave all five answering to one name.
    @MainActor
    func testPicksARouteLinePattern() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=ThumseeLoopFast",
            ]
        )
        app.launch()

        let hikeTitle = app.staticTexts[Self.importedHikeTitle]
        XCTAssertTrue(hikeTitle.waitForExistence(timeout: 15))
        hikeTitle.tap()
        XCTAssertTrue(
            app.navigationBars[Self.importedHikeTitle]
                .waitForExistence(timeout: 5)
        )

        let directional = element("route-pattern-directional", in: app)
        let dotted = element("route-pattern-dotted", in: app)
        XCTAssertTrue(directional.waitForExistence(timeout: 10))
        XCTAssertTrue(
            directional.isSelected,
            "a hike starts on the line-with-arrows it has always been drawn as"
        )

        tap(dotted, in: app)
        XCTAssertTrue(
            waitUntilSelected(dotted),
            "tapping a swatch should move the selection to it"
        )
        XCTAssertFalse(directional.isSelected)
    }

    @MainActor
    func testLaunchPerformance() {        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(
            metrics: [XCTApplicationLaunchMetric()],
            options: options
        ) {
            makeApp().launch()
        }
    }

    @MainActor
    private func makeApp(
        arguments: [String] = []
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        return app
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func addLocationPermissionMonitor() {
        addUIInterruptionMonitor(
            withDescription: "Location permission"
        ) { alert in
            guard alert.buttons.count >= 2 else { return false }
            // Location prompts put affirmative choices before the final
            // localized denial action.
            alert.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    @MainActor
    private func setSimulatedLocation(
        latitude: CLLocationDegrees,
        longitude: CLLocationDegrees
    ) {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            altitude: 535,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: .now
        )
        XCUIDevice.shared.location = XCUILocation(location: location)
    }

    @MainActor
    private func setSimulatedLocation(_ coordinate: CLLocationCoordinate2D) {
        setSimulatedLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// Steps the simulator through the fixture trace, waiting for the recorder
    /// to accept each coordinate rather than guessing at a fix interval. A
    /// static simulated location is delivered once, so a fix the recorder turns
    /// down has to be handed to it again.
    @MainActor
    private func walkRecordedTrace(in app: XCUIApplication) {
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: 15))

        for (index, coordinate) in Self.recordedTrace.enumerated() {
            if index > 0 {
                // The recorder rejects a step it would have to sprint, so the
                // trace is walked at a believable pace.
                Thread.sleep(forTimeInterval: Self.paceSeconds)
                setSimulatedLocation(coordinate)
            }
            XCTAssertTrue(
                waitForPointCount(atLeast: index + 1, in: points) {
                    self.setSimulatedLocation(coordinate)
                },
                "the recorder never accepted fix \(index + 1)"
            )
        }
    }

    @MainActor
    private func waitForPointCount(
        atLeast count: Int,
        in element: XCUIElement,
        timeout: TimeInterval = 40,
        redeliver: () -> Void
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String,
               let recorded = Int(value), recorded >= count {
                return true
            }
            Thread.sleep(forTimeInterval: Self.paceSeconds)
            redeliver()
        }
        return false
    }

    @MainActor
    private func stopRecording(in app: XCUIApplication) {
        app.buttons["Stop"].tap()
        let namePrompt = app.alerts["Name Your Hike"]
        XCTAssertTrue(namePrompt.waitForExistence(timeout: 5))
        // The name is typed before the review opens, so saving it later also
        // proves the review step carries it through.
        let field = namePrompt.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let draft = field.value as? String, !draft.isEmpty {
            field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        }
        field.typeText(Self.reviewedHikeName)
        XCTAssertEqual(field.value as? String, Self.reviewedHikeName)
        namePrompt.buttons["Save"].tap()
    }

    /// The review runs past the bottom of a half-height sheet, so a control has
    /// to be scrolled into reach before it can be tapped.
    @MainActor
    private func tap(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        let sheet = app.scrollViews.firstMatch
        var attempts = 0
        while !target.isHittable, attempts < 5, sheet.exists {
            sheet.swipeUp()
            attempts += 1
        }
        target.tap()
    }

    @MainActor
    private func waitUntilSelected(
        _ target: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.isSelected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
