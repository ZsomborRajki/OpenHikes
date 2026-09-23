//
//  OpenHikesUITests+WeatherAttribution.swift
//  OpenHikesUITests
//
//  Apple Weather's credits are where someone opening the weather sheet sees
//  them. App Review rejected 1.1 (7) under guideline 5.2.5 because the mark was
//  at the bottom of a long list, below the fold. The assertion is that both
//  the mark and the legal link can be tapped straight away: `List` builds rows
//  lazily, so a row below the fold would not even exist yet, and a row that
//  exists but is covered is not hittable.
//

import XCTest

extension OpenHikesUITests {
    @MainActor
    func testTheWeatherSheetOpensOnAppleWeathersCredits() {
        let app = launchApp(arguments: ["--ui-test-weather"])

        tapWhenReady(element("weather-badge", in: app))

        let mark = element("weather-mark", in: app)
        XCTAssertTrue(
            mark.waitForExistence(timeout: UITestTimeout.existence),
            "the sheet should lead with the Apple Weather mark"
        )
        XCTAssertTrue(mark.isHittable, "the mark should be on screen without scrolling")
        XCTAssertEqual(mark.label, "Apple Weather")

        let legal = element("weather-legal-link-top", in: app)
        XCTAssertTrue(
            legal.waitForExistence(timeout: UITestTimeout.existence),
            "the legal link should sit beside the mark"
        )
        XCTAssertTrue(legal.isHittable, "the legal link should be on screen without scrolling")
    }
}
