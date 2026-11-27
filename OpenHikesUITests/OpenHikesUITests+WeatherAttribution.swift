//
//  OpenHikesUITests+WeatherAttribution.swift
//  OpenHikesUITests
//
//  Apple Weather's credits are where someone opening the weather sheet sees
//  them. App Review rejected 1.1 (7) under guideline 5.2.5 because the mark was
//  at the bottom of a long list, below the fold. The assertion is that both
//  the mark and the legal link can be tapped straight away: an element below
//  the fold, or one that is covered, is not hittable.
//
//  At the largest accessibility text size, and opened twice: once whole, and
//  once more after the hiker dragged it down to half height and closed it,
//  which is the height it then reopens at. The head of the sheet sets the
//  temperature large, and while the credits stood under it a half sheet at
//  that size reopened with the mark below the screen and only the top edge
//  of *Legal* in view.
//

import XCTest

extension OpenHikesUITests {
    @MainActor
    func testTheWeatherSheetOpensOnAppleWeathersCredits() {
        let app = launchApp(arguments: ["--ui-test-weather"] + Self.largestTextSize)

        tapWhenReady(element("weather-badge", in: app))
        assertAppleWeathersCreditsAreOnScreen(in: app, "as the sheet opens")

        collapseWeatherSheet(in: app)
        tapWhenReady(element("weather-detail-done", in: app))
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                !element("weather-mark", in: app).exists
            },
            "the sheet should close on Done"
        )

        tapWhenReady(element("weather-badge", in: app))
        assertAppleWeathersCreditsAreOnScreen(in: app, "as the sheet reopens at half height")
    }

    @MainActor
    private func assertAppleWeathersCreditsAreOnScreen(in app: XCUIApplication, _ moment: String) {
        let mark = element("weather-mark", in: app)
        XCTAssertTrue(
            mark.waitForExistence(timeout: UITestTimeout.existence),
            "the sheet should lead with the Apple Weather mark \(moment)"
        )
        XCTAssertTrue(mark.isHittable, "the mark should be on screen without scrolling \(moment)")
        XCTAssertEqual(mark.label, "Apple Weather")

        let legal = element("weather-legal-link-top", in: app)
        XCTAssertTrue(
            legal.waitForExistence(timeout: UITestTimeout.existence),
            "the legal link should sit beside the mark \(moment)"
        )
        XCTAssertTrue(legal.isHittable, "the legal link should be on screen without scrolling \(moment)")
    }

    /// Drags the weather sheet down to its half-height detent and waits for
    /// it to land there.
    ///
    /// The map's own sheet is still presented under it, with a grabber of
    /// its own, so the weather sheet's is the one nearer the top of the
    /// screen. A detent is waited on as a frame, as `PhotoUITests` does: the
    /// sheet's Done button is in its bar, so it is down by the middle of the
    /// screen once the sheet is.
    @MainActor
    private func collapseWeatherSheet(in app: XCUIApplication) {
        let grabbers = app.buttons.matching(NSPredicate(format: "label == %@", "Sheet Grabber"))
        XCTAssertTrue(
            grabbers.firstMatch.waitForExistence(timeout: UITestTimeout.navigation),
            "the weather sheet should offer a grabber to drag"
        )
        let grabber = grabbers.allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY } ?? grabbers.firstMatch
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: Self.weatherSheetDragPress,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: Self.weatherSheetHalfway))
            )
        let done = element("weather-detail-done", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                done.frame.minY > app.frame.height * Self.weatherSheetLoweredFraction
            },
            "the weather sheet should have come to rest at half height"
        )
    }

    /// UIKit's own launch default for the reader's text size, at the largest
    /// accessibility size it has.
    private static let largestTextSize = [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    private static let weatherSheetDragPress: TimeInterval = 0.1
    /// Where the grabber is let go, as a share of the screen's height: just
    /// under the half-height detent, which the sheet then settles on.
    private static let weatherSheetHalfway = 0.55
    /// Below this share of the screen's height, the sheet's bar is no longer
    /// where a whole sheet puts it.
    private static let weatherSheetLoweredFraction: CGFloat = 0.3
}
