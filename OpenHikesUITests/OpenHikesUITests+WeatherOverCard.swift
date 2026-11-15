//
//  OpenHikesUITests+WeatherOverCard.swift
//  OpenHikesUITests
//
//  The weather badge stays live beside a place card, and the map sheet is
//  already presenting the card. The forecast asked for from under it waited,
//  and came up only once the card was closed, over a map the hiker had moved
//  on from (#1403). Which view presents is resolved only by a running app.
//

import XCTest

extension OpenHikesUITests {
    @MainActor
    func testTheForecastOpensOverAPlaceCard() {
        let app = launchApp(arguments: PlaceFixture.aroundArguments + ["--ui-test-weather"])
        let card = openFoundPlaceCard(in: app)

        tapWhenReady(element("weather-badge", in: app))
        let conditions = element("weather-detail-conditions", in: app)
        XCTAssertTrue(
            conditions.waitForExistence(timeout: UITestTimeout.navigation),
            "the badge should open the forecast over the card"
        )
        tapWhenReady(element("weather-detail-done", in: app))
        XCTAssertTrue(waitUntil { !conditions.exists }, "Done should close the forecast")
        XCTAssertTrue(card.exists, "the card should still be up under it")

        app.buttons["places-around-card-close"].tap()
        XCTAssertTrue(waitUntil { !card.exists })
        // A sheet that had queued behind the card comes up only once the
        // card has finished going, so this waits out that much.
        XCTAssertFalse(
            conditions.waitForExistence(timeout: UITestTimeout.brief),
            "closing the card should bring nothing back"
        )
    }
}
