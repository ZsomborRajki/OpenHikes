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

    @MainActor
    func testTravelModeIconsChangeTheRouteAndKeepTheStops() {
        let app = launchApp()
        openTrailMaker(in: app)
        let hiking = element("trail-draft-mode-hiking", in: app)
        XCTAssertTrue(hiking.isSelected)
        let map = element("trail-map", in: app)
        drawTrailPoints(Self.travelModePoints, on: map, in: app)

        for mode in ["walking", "cycling", "driving"] {
            let button = element("trail-draft-mode-\(mode)", in: app)
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(waitUntil { button.isSelected })
            XCTAssertFalse(hiking.isSelected)
            XCTAssertTrue(element("trail-draft-point-2", in: app).exists)
            XCTAssertTrue(element("trail-draft-save", in: app).isEnabled)
            XCTAssertTrue(waitUntil {
                element("trail-draft-point-2", in: app).label.contains("No route found for this travel mode")
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
