//
//  WalkUITests+JunctionWarnings.swift
//  OpenHikesUITests
//
//  The junction warnings button on the map's leading edge — see
//  `MapCoordinator+JunctionButton.swift`. What it makes the phone say is
//  `JunctionGuideTests`'s to check: a UI launch takes no fixes for it and
//  says nothing aloud.
//

import XCTest

extension WalkUITests {
    /// There while a walk is under way and not before, off until it is
    /// tapped, and its state is its accessibility trait.
    @MainActor
    func testJunctionWarningsAreSwitchedFromTheMapDuringAWalk() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"])
        openHikeDetail(in: app)
        let toggle = app.buttons["walk-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: UITestTimeout.existence))
        let button = element("map-junction-warnings-button", in: app)
        XCTAssertFalse(button.exists, "a trail nobody is walking offers no warnings")

        toggle.tap()

        XCTAssertTrue(
            button.waitForExistence(timeout: UITestTimeout.existence),
            "a walk under way offers the button on the map"
        )
        XCTAssertEqual(button.label, "Junction Warnings")
        XCTAssertFalse(button.isSelected, "the warnings are off until the hiker turns them on")
        button.tap()
        XCTAssertTrue(waitUntilSelected(button), "a tap turns them on")
        button.tap()
        XCTAssertTrue(waitUntil { !button.isSelected }, "and another turns them off")
    }
}
