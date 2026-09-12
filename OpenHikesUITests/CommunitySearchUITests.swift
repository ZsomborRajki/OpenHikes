import XCTest

nonisolated final class CommunitySearchUITests: XCTestCase {
    /// Deterministic community rows, and no place autocomplete under them, so
    /// the fallback rows these scenarios drive are reachable without depending
    /// on what MapKit answers for a fragment on the day the suite runs.
    private static let launchArguments = [
        "--ui-test-expanded-sheet",
        "--ui-test-community",
        "--ui-test-no-place-suggestions",
    ]

    @MainActor
    func testPlaceDiscoveryPreviewAndSaving() {
        let app = launchApp(arguments: Self.launchArguments)
        let search = element("map-search", in: app)
        search.tap()
        search.typeText("Dobogókő")
        let around = element("community-around-query", in: app)
        XCTAssertTrue(around.waitForExistence(timeout: UITestTimeout.existence))
        around.tap()
        let area = element("community-search-area", in: app)
        XCTAssertTrue(area.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(area.label.contains("Dobogókő"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Community search around Dobogókő"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let row = app.buttons.matching(identifier: "community-hike-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        row.tap()
        let save = element("community-import-button", in: app)
        XCTAssertTrue(save.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertEqual(save.label, "Save to Your Hikes")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(area.label.contains("Dobogókő"))
        row.tap()
        XCTAssertTrue(save.waitForExistence(timeout: UITestTimeout.existence))
        save.tap()
        XCTAssertTrue(element("walk-segment", in: app).waitForExistence(timeout: UITestTimeout.existence))
    }

    @MainActor
    func testScopesEmptyResultsAndFailureRemainVisibleAfterSubmit() {
        let app = launchApp(arguments: Self.launchArguments)
        element("search-scope-community", in: app).tap()
        element("community-search-area", in: app).tap()
        app.buttons["Anywhere"].tap()
        let search = element("map-search", in: app)
        search.tap()
        search.typeText("NoSuchHike\n")
        XCTAssertTrue(element("community-search-empty", in: app).waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertFalse(element("import-gpx-button", in: app).exists)
        element("clear-search-button", in: app).tap()
        search.tap()
        search.typeText("Offline\n")
        XCTAssertTrue(element("community-search-failure", in: app).waitForExistence(timeout: UITestTimeout.existence))
        element("search-scope-yourHikes", in: app).tap()
        XCTAssertFalse(element("community-search-failure", in: app).exists)
        XCTAssertTrue(app.staticTexts["No saved hikes match this search."].exists)
    }

    @MainActor
    func testChooseAreaPreservesTheHikeQuery() throws {
        let app = launchApp(arguments: Self.launchArguments)
        element("search-scope-community", in: app).tap()
        element("community-search-area", in: app).tap()
        app.buttons["Anywhere"].tap()
        let search = element("map-search", in: app)
        search.tap()
        search.typeText("Ridge\n")
        let row = app.buttons.matching(identifier: "community-hike-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        element("community-search-area", in: app).tap()
        app.buttons["Choose a place…"].tap()
        let place = element("community-place-search", in: app)
        XCTAssertTrue(place.waitForExistence(timeout: UITestTimeout.existence))
        place.tap()
        place.typeText("Pilis")
        element("community-place-submit", in: app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertEqual(search.value as? String, "Ridge")
        XCTAssertTrue(element("community-search-area", in: app).label.contains("Pilis"))
        XCTAssertTrue(element("search-scope-community", in: app).isSelected)
        try audit(app)
        row.tap()
        XCTAssertTrue(element("community-import-button", in: app).waitForExistence(timeout: UITestTimeout.existence))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertEqual(search.value as? String, "Ridge")
    }

    @MainActor
    func testPanningKeepsResultsUntilSearchThisArea() {
        let app = launchApp(arguments: Self.launchArguments)
        let search = element("map-search", in: app)
        search.tap()
        search.typeText("Pilis")
        let around = element("community-around-query", in: app)
        XCTAssertTrue(around.waitForExistence(timeout: UITestTimeout.existence))
        around.tap()
        let rows = app.buttons.matching(identifier: "community-hike-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: UITestTimeout.existence))
        let originalLabels = rows.allElementsBoundByIndex.map(\.label)
        let map = element("trail-map", in: app)
        let start = map.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2))
        let end = map.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
        start.press(forDuration: 0, thenDragTo: end)
        let refresh = element("community-search-this-area", in: app)
        XCTAssertTrue(refresh.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertEqual(rows.allElementsBoundByIndex.map(\.label), originalLabels)
        XCTAssertTrue(element("community-search-area", in: app).label.contains("Pilis"))
        refresh.tap()
        XCTAssertTrue(element("community-search-area", in: app).label.contains("This map"))
    }

    @MainActor
    func testNearMeWithoutLocationOffersThePlacePicker() {
        let app = launchApp(arguments: Self.launchArguments)
        element("search-scope-community", in: app).tap()
        element("community-search-area", in: app).tap()
        app.buttons["Near me"].tap()
        let alert = app.alerts["Location unavailable"]
        XCTAssertTrue(alert.waitForExistence(timeout: UITestTimeout.existence))
        alert.buttons["Choose a place"].tap()
        XCTAssertTrue(element("community-place-search", in: app).waitForExistence(timeout: UITestTimeout.existence))
    }

    /// Without a transport the Community scope is absent, so All cannot offer
    /// the community fallback either — and Return does not geocode outside
    /// Places. What is left under an empty suggestion list has to say so.
    @MainActor
    func testAllScopeWithoutCommunityPointsAtThePlacesScope() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet", "--ui-test-no-place-suggestions"])
        XCTAssertFalse(element("search-scope-community", in: app).exists)
        let search = element("map-search", in: app)
        search.tap()
        search.typeText("Dobogoko")
        let hint = app.staticTexts["No place suggestions. Switch to Places to look this up on the map."]
        XCTAssertTrue(hint.waitForExistence(timeout: UITestTimeout.existence))
    }

}
