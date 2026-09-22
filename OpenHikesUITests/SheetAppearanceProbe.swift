import XCTest

nonisolated final class SheetAppearanceProbe: XCTestCase {
    @MainActor
    func testCapture() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.buttons["Allow While Using App"]
        if permission.waitForExistence(timeout: 3) {
            permission.tap()
        }
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }

        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "-settings.tileProviderID", "apple_maps",
        ])
        XCTAssertTrue(element("map-search", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        capture("OpenHikes medium")

        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        maps.activate()
        let notNow = maps.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }
        let mapsPermission = springboard.buttons["Allow While Using App"]
        if mapsPermission.waitForExistence(timeout: 3) {
            mapsPermission.tap()
        }
        capture("Apple Maps")
        app.activate()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        capture("OpenHikes landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        element("map-search", in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: UITestTimeout.navigation))
        capture("OpenHikes expanded")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
