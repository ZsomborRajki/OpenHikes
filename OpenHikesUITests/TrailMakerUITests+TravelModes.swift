import XCTest

extension TrailMakerUITests {
    private static let firstPointX = 0.45
    private static let firstPointY = 0.20
    private static let secondPointX = 0.65
    private static let secondPointY = 0.30
    private static let travelModePoints = [
        CGVector(dx: firstPointX, dy: firstPointY),
        CGVector(dx: secondPointX, dy: secondPointY),
    ]

    /// A segment of the system's segmented control, found by the word it is
    /// spoken by. Its content's own identifiers are not guaranteed to reach
    /// the automation through the control, the way a `Menu`'s entries do not.
    private func travelMode(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.segmentedControls["trail-draft-mode"].buttons[label]
    }

    @MainActor
    func testTravelModeIconsChangeTheRouteAndKeepTheStops() {
        let app = launchApp()
        openTrailMaker(in: app)
        let hiking = travelMode("Hiking", in: app)
        XCTAssertEqual(
            app.segmentedControls["trail-draft-mode"].buttons.element(boundBy: 0).label,
            "Hiking",
            "Hiking should be the first travel mode"
        )
        XCTAssertTrue(hiking.isSelected)
        let map = element("trail-map", in: app)
        drawTrailPoints(Self.travelModePoints, on: map, in: app)

        for mode in ["Walking", "Cycling", "Driving"] {
            let button = travelMode(mode, in: app)
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(waitUntil { button.isSelected })
            XCTAssertFalse(hiking.isSelected)
            XCTAssertTrue(element("trail-draft-point-2", in: app).exists)
            XCTAssertTrue(element("trail-draft-save", in: app).isEnabled)
            XCTAssertTrue(waitUntil {
                (element("trail-draft-point-2", in: app).value as? String ?? "")
                    .contains("No route found for this travel mode")
            })
        }
        hiking.tap()
        XCTAssertTrue(waitUntil { hiking.isSelected })
        XCTAssertTrue(element("trail-draft-point-2", in: app).exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Travel mode selector"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
