//
//  RouteColoringUITests.swift
//  OpenHikesUITests
//
//  The *Color By* control on Route Style: three segments, one selected, the
//  key under it relabelled for the mode, and the choice still there when the
//  screen is pushed again. Where the colours come from is `RouteShadingTests`'
//  and `RouteSteepnessTests`'; this is the part a hiker touches.
//

import XCTest

nonisolated final class RouteColoringUITests: XCTestCase {
    /// Within one launch, for the reason `testSettingsTogglesHoldTheirValue`
    /// gives: UI-testing defaults are wiped at startup, so what is the app's
    /// to get right is the screen rebuilt from the stored choice.
    @MainActor
    func testPicksARouteColoring() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)
        openRouteStyle(in: app)

        let picker = app.segmentedControls["route-coloring-picker"]
        XCTAssertTrue(
            scrollIntoView(picker, in: app),
            "the control has to be fully on screen before it can be aimed at"
        )
        XCTAssertTrue(
            picker.buttons["Elevation"].isSelected,
            "lines are coloured by steepness until the hiker says otherwise"
        )
        XCTAssertTrue(element("Steepness colors", in: app).exists)

        picker.buttons["Difficulty"].tap()
        XCTAssertTrue(
            waitUntilSelected(picker.buttons["Difficulty"]),
            "tapping a segment should move the selection to it"
        )
        XCTAssertFalse(picker.buttons["Elevation"].isSelected)
        XCTAssertTrue(
            element("Difficulty colors", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the key should be labelled for difficulty once the line is coloured by it"
        )

        popScreen(in: app)
        openRouteStyle(in: app)
        let reopened = app.segmentedControls["route-coloring-picker"]
        scrollIntoView(reopened, in: app)
        XCTAssertTrue(
            reopened.buttons["Difficulty"].isSelected,
            "the choice is every hike's, so it should still be there when the screen is rebuilt"
        )
    }
}
