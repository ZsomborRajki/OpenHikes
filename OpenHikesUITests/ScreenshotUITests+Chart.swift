//
//  ScreenshotUITests+Chart.swift
//  OpenHikesUITests
//
//  Select a place on the trail by the chart's spoken progress, not a guessed
//  share of its frame: that frame includes axes whose widths vary by device
//  and locale. Each tap narrows the measured range until the tracker agrees.
//

import XCTest

extension ScreenshotUITests {
    private static let lateChartProgress = 90
    private static let endChartProgress = 99
    private static let middleChartProgress = 50
    private static let chartRegressionProgress = [
        lateChartProgress, endChartProgress, middleChartProgress, middleChartProgress, 1,
    ]

    /// Exercise the capture helper where probes can land beyond the plot,
    /// and where a second selection already has the requested rounded value.
    @MainActor
    func testSelectsChartProgressThroughAxesAndRoundedValues() throws {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(scrollIntoView(chart, in: app))
        let before = chart.value as? String ?? ""
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(waitUntilValueChanges(from: before, on: chart))
        let value = chart.value as? String ?? ""
        let match = try XCTUnwrap(value.firstMatch(of: /([0-9]+)\s*%/))
        // The helper's first probe now selects exactly the existing value.
        selectChartProgress(try XCTUnwrap(Int(match.1)), in: app)
        for percent in Self.chartRegressionProgress {
            selectChartProgress(percent, in: app)
        }
    }

    @MainActor
    func selectChartProgress(_ targetPercent: Int, in app: XCUIApplication) {
        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(scrollIntoView(chart, in: app), "the hike should draw its elevation chart")
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        var lastResponsivePosition: CGFloat?
        for _ in 0..<12 {
            let before = chart.value as? String ?? ""
            let position = (lower + upper) / 2
            chart.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).tap()
            let changed = waitUntilValueChanges(from: before, on: chart, timeout: UITestTimeout.brief)
            let value = chart.value as? String ?? ""
            guard let match = value.firstMatch(of: /([0-9]+)\s*%/),
                  let percent = Int(match.1) else {
                XCTFail("the chart should report progress along the trail: \(value)")
                return
            }
            if abs(percent - targetPercent) <= 1 { return }
            // Axes do not select a point, and nearby probes can speak the
            // same rounded value. Keep searching inside the responsive plot.
            if !changed, let lastResponsivePosition {
                if position > lastResponsivePosition {
                    upper = position
                } else {
                    lower = position
                }
                continue
            }
            lastResponsivePosition = position
            if percent < targetPercent {
                lower = position
            } else {
                upper = position
            }
        }
        XCTFail("the chart never reached \(targetPercent)%: \(String(describing: chart.value))")
    }
}
