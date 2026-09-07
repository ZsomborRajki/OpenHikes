import XCTest

extension OpenHikesUITests {
    @MainActor
    func testTappingElevationChartMovesAndKeepsTheTracker() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
        ])
        openHikeDetail(in: app)

        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: UITestTimeout.existence))
        let initial = chart.value as? String ?? ""
        XCTAssertFalse(initial.isEmpty)

        chart.coordinate(withNormalizedOffset: CGVector(dx: Self.laterChartPosition, dy: 0.5)).tap()
        XCTAssertTrue(
            waitUntilValueChanges(from: initial, in: chart),
            "a tap must move the tracker and retain its readout after release"
        )
        let firstTap = chart.value as? String ?? ""

        chart.coordinate(withNormalizedOffset: CGVector(dx: Self.earlierChartPosition, dy: 0.5)).tap()
        XCTAssertTrue(
            waitUntilValueChanges(from: firstTap, in: chart),
            "a second tap must move the tracker to the newly tapped distance"
        )
        XCTAssertNotEqual(chart.value as? String, initial)
    }

    private static let laterChartPosition = 0.7
    private static let earlierChartPosition = 0.3
}
