//
//  PlaceUITests+Around.swift
//  OpenHikesUITests
//
//  *Places Around Trail*: what OpenStreetMap has on and near a saved hike,
//  on the map and in a list, added one at a time — and a place of the hiker's
//  own anywhere a press on the map lands.
//
//  Against ``SeededTrailPointSource``: three places on the fixture's line and
//  a summit about 420 m off it, so both sections of the list and a pale pin
//  that is not on the trail are on screen.
//

import XCTest

extension PlaceUITests {
    /// The summit off the line, which only a reach wider than the trail finds.
    private static let nearbySummit = "Thumsee Kopf"
    /// Where the press lands: high on the map, clear of the sheet at its
    /// middle detent and of the pill in the strip at the top.
    private static let pressFraction = 0.3
    private static let pressSpot = CGVector(dx: pressFraction, dy: pressFraction)

    @MainActor
    func testPlacesAroundAddsAPlaceOffTheTrail() {
        let app = openPlacesAround()
        let nearby = element("places-around-nearby", in: app)
        XCTAssertTrue(nearby.waitForExistence(timeout: UITestTimeout.navigation), "a place off the line is Nearby")
        XCTAssertTrue(element("hike-place-candidate", in: app).exists, "and stands on the map as a pale pin")

        scrollToTap(app.buttons["Add \(Self.nearbySummit)"], in: app)

        XCTAssertTrue(
            app.buttons["Add \(Self.nearbySummit)"].waitForNonExistence(timeout: UITestTimeout.existence),
            "adding is immediate, with no Add for a batch"
        )
        popScreen(in: app)
        XCTAssertTrue(app.navigationBars[PlaceFixture.hikeTitle].waitForExistence(timeout: UITestTimeout.navigation))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.nearbySummit)).firstMatch
        scrollIntoView(row, in: app)
        XCTAssertTrue(row.exists, "the hike keeps the place")
        XCTAssertTrue(row.label.contains("off trail"), "and says how far off the trail it stands")
    }

    @MainActor
    func testPlacesAroundNarrowsToTheTrailWithoutAsking() {
        let app = openPlacesAround()
        let nearby = element("places-around-nearby", in: app)
        XCTAssertTrue(nearby.waitForExistence(timeout: UITestTimeout.navigation))

        app.segmentedControls["places-around-reach"].buttons["On Trail"].tap()

        XCTAssertTrue(nearby.waitForNonExistence(timeout: UITestTimeout.existence), "On Trail leaves out what is near")
        XCTAssertTrue(element("places-around-on-trail", in: app).exists, "and keeps what the line passes")
        XCTAssertFalse(element("places-around-searching", in: app).exists, "narrowing asks nothing")
    }

    @MainActor
    func testPlacesAroundCardAddsThePlaceAndTakesItsPhotos() {
        let app = openPlacesAround()
        XCTAssertTrue(element("places-around-nearby", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.nearbySummit)).firstMatch
        scrollToTap(row, in: app)

        let add = element("places-around-card-add", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: UITestTimeout.navigation), "a found place's row opens its card")
        XCTAssertEqual(element("places-around-card-title", in: app).label, Self.nearbySummit)
        add.tap()

        XCTAssertTrue(
            element("places-around-card-camera", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "once added, the same card takes the place's photographs"
        )
        XCTAssertTrue(element("places-around-card-library", in: app).exists)
        XCTAssertFalse(element("hike-place-screen", in: app).exists, "and nothing was pushed over the screen")
    }

    @MainActor
    func testAPlaceOnTheHikeOpensItsCardRatherThanAScreen() {
        let app = openPlacesAround()
        XCTAssertTrue(element("places-around-on-trail", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", PlaceFixture.ownPlace)).firstMatch
        scrollToTap(row, in: app)

        XCTAssertTrue(
            element("places-around-card-camera", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a place the hike has opens the card, with its camera"
        )
        XCTAssertEqual(element("places-around-card-title", in: app).label, PlaceFixture.ownPlace)
        XCTAssertFalse(element("hike-place-screen", in: app).exists, "not the place's pushed screen")
    }

    @MainActor
    func testPressingTheMapAddsAPlaceOfTheHikersOwn() {
        let app = openPlacesAround()
        XCTAssertTrue(element("places-around-screen", in: app).waitForExistence(timeout: UITestTimeout.navigation))

        // The maker's own press, held past the map's half second.
        dropPin(at: Self.pressSpot, on: element("trail-map", in: app))

        XCTAssertTrue(
            element("hike-place-adder-title", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a press on the map opens Add Place there"
        )
        XCTAssertTrue(
            element("hike-place-placeholder", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "with a pin where it will go"
        )
        app.buttons["hike-place-adder-add"].tap()
        XCTAssertTrue(element("hike-place-title", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        popScreen(in: app)
        XCTAssertTrue(
            element("places-around-screen", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "back from the new place is Places Around Trail"
        )
    }

    @MainActor
    private func openPlacesAround() -> XCUIApplication {
        let app = launchApp(
            arguments: [
                "--ui-test-import-gpx=\(PlaceFixture.gpxName)",
                "--ui-test-trail-points=seeded",
            ]
        )
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        scrollToTap(element("hike-place-search", in: app), in: app)
        return app
    }
}
