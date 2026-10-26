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
    @MainActor
    func selectChartProgress(_ targetPercent: Int, in app: XCUIApplication) {
        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(scrollIntoView(chart, in: app), "the hike should draw its elevation chart")
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<8 {
            let before = chart.value as? String ?? ""
            let position = (lower + upper) / 2
            chart.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).tap()
            XCTAssertTrue(
                waitUntilValueChanges(from: before, on: chart),
                "tapping the chart should move the tracker"
            )
            let value = chart.value as? String ?? ""
            guard let match = value.firstMatch(of: /([0-9]+)% along the trail/),
                  let percent = Int(match.1) else {
                XCTFail("the chart should report progress along the trail: \(value)")
                return
            }
            if abs(percent - targetPercent) <= 1 { return }
            if percent < targetPercent {
                lower = position
            } else {
                upper = position
            }
        }
        XCTFail("the chart never reached \(targetPercent)%: \(String(describing: chart.value))")
    }
}
