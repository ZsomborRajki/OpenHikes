// Selecting the order whose figures arrive from the background sweep must
// keep the list navigable while its cache is being published.

import XCTest

extension HikeOrderUITests {
    @MainActor
    func testHilliestSortKeepsHikesOpenable() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet", "--ui-test-seed-hikes=4"])
        let sort = app.buttons["hike-order-button"]
        XCTAssertTrue(sort.waitForExistence(timeout: UITestTimeout.existence))

        sort.tap()
        let hilliest = app.buttons["Hilliest"]
        XCTAssertTrue(hilliest.waitForExistence(timeout: UITestTimeout.existence))
        hilliest.tap()
        XCTAssertTrue(waitUntil { sort.value as? String == "Hilliest" })

        // Every seeded hike has the same route. The elevation order keeps
        // their date tie-breaker and must leave every row available to open.
        let first = awaitHikeRow(titled: "Seeded Trail 1", in: app)
        let third = awaitHikeRow(titled: "Seeded Trail 3", in: app)
        XCTAssertLessThan(first.frame.minY, third.frame.minY)
        third.tap()
        XCTAssertTrue(
            app.navigationBars["Seeded Trail 3"].waitForExistence(timeout: UITestTimeout.navigation)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(sort.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertEqual(sort.value as? String, "Hilliest")
    }
}
