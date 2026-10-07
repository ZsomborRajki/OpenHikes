//
//  AccessibilityUITests+ElevationPro.swift
//  OpenHikesUITests
//
//  The empty elevation card that sells the heights (#785), which no sweep had
//  seen (#794): it is drawn only for a route with no heights at all, and every
//  other fixture the suites import carries them.
//
//  `ThumseeLoopNoHeights` is the Thumsee loop with its `<ele>`s taken out, and
//  a UI-testing launch without `--ui-test-entitled` is one StoreKit has
//  answered *not entitled* for — the only state the card is drawn in.
//

import XCTest

extension AccessibilityUITests {
    @MainActor
    func testElevationProCardPassesAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(Self.heightlessGPX)",
            ]
        )
        openHikeDetail(in: app, titled: Self.heightlessTitle)
        XCTAssertTrue(
            scrollUntilVisible(element("elevation-pro-prompt", in: app), in: app),
            "a hike with no heights offers them with OpenHikes Pro"
        )

        try audit(app)
    }

    private static let heightlessGPX = "ThumseeLoopNoHeights"
    private static let heightlessTitle = "Thumsee Loop (no heights)"
}
