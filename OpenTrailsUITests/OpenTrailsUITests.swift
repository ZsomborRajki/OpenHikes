//
//  OpenTrailsUITests.swift
//  OpenTrailsUITests
//

import CoreLocation
import XCTest

final class OpenTrailsUITests: XCTestCase {
    private static let importedHikeTitle =
        "Thumsee Loop (fast, simulated)"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

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

    @MainActor
    func testLaunchPerformance() {
        let options = XCTMeasureOptions()
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
}
