//
//  OpenHikesUITests+ElevationChart.swift
//  OpenHikesUITests
//
//  The tap half of the elevation profile's scrub. Split out from the main
//  bundle file because the drag half already has a home —
//  `AccessibilityLabelUITests.testElevationChartIsReadableAndAdjustable`
//  scrubs by dragging and reads the spoken value back — and the two failed
//  independently: Swift Charts' own selection gesture needs about a tenth of
//  a second of press before it resolves anything, so a drag has always worked
//  while a brisk tap selected nothing at all. See #206.
//
//  `XCUICoordinate.tap()` is the assertion's whole point rather than an
//  implementation detail: its synthesised touch is instantaneous, so it is
//  strictly briefer than any human tap, and a chart that answers it answers
//  every real one.
//

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
