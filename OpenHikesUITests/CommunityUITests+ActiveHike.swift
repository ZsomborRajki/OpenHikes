//
//  CommunityUITests+ActiveHike.swift
//  OpenHikesUITests
//
//  The walk under way, pinned above the published hikes as it is above the
//  hiker's own — see ``MapSheetHikes/activeHikeSection``.
//

import XCTest

extension CommunityUITests {
    /// A walk started by hand, then the Community tab: the trail being walked
    /// is the first thing on it, badge and all, and one tap from its screen.
    @MainActor
    func testAWalkUnderWayIsPinnedAboveTheCommunityList() {
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)
        let toggle = app.buttons["walk-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: UITestTimeout.existence))
        toggle.tap()
        XCTAssertTrue(element("walk-phase", in: app).waitForExistence(timeout: UITestTimeout.existence))
        popScreen(in: app)

        selectCommunityTab(in: app)
        XCTAssertTrue(
            communityRow(titled: SeededHike.allTitles[0], in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the published hikes are listed"
        )
        let pinned = hikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        XCTAssertTrue(pinned.exists, "and the trail being walked is pinned above them")

        pinned.tap()
        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "one tap from its screen"
        )
    }
}
