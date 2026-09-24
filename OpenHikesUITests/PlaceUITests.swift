//
//  PlaceUITests.swift
//  OpenHikesUITests
//
//  A saved hike's places, opened from its screen.
//
//  The fixture is the Thumsee loop with two `<wpt>`s on it: a boathouse the
//  file describes itself, which is the hiker's own place to rename, and a
//  spring carrying an openstreetmap.org link, which comes back
//  OpenStreetMap's — photographs only. The rule these defend is the user's:
//  a place from OpenStreetMap is edited only by adding pictures to it.
//
//  And the pins those places stand on the map as: kept there while the hike's
//  History is read, and taken away — not deleted — by the switch beside the
//  *Places* heading.
//

import XCTest

nonisolated final class PlaceUITests: XCTestCase {
    private static let fixture = "ThumseeLoopPlaces"
    private static let hikeTitle = "Thumsee Loop (places)"

    @MainActor
    private func openPlace(named name: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        scrollToTap(row, in: app)
        let title = element("hike-place-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "a place row should open its screen")
        XCTAssertEqual(title.label, name)
    }

    @MainActor
    func testTheHikersOwnPlaceOpensAndCanBeEdited() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openHikeDetail(in: app, titled: Self.hikeTitle)

        openPlace(named: "Boathouse", in: app)

        XCTAssertTrue(app.buttons["hike-place-edit"].exists, "a place the hiker made can be edited")
        XCTAssertTrue(element("hike-place-camera", in: app).exists, "every place takes photographs")
        XCTAssertFalse(element("trail-place-osm-link", in: app).exists)
    }

    @MainActor
    func testAnOpenStreetMapPlaceTakesPhotographsOnly() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openHikeDetail(in: app, titled: Self.hikeTitle)

        openPlace(named: "Thumsee Spring", in: app)

        XCTAssertTrue(element("hike-place-camera", in: app).exists, "every place takes photographs")
        XCTAssertFalse(
            app.buttons["hike-place-edit"].exists,
            "OpenStreetMap's name and kind are not the hiker's to change"
        )
        scrollIntoView(element("trail-place-osm-link", in: app), in: app)
        XCTAssertTrue(element("trail-place-osm-link", in: app).exists, "it links to where it is corrected")
    }

    @MainActor
    func testRemovingAPlaceReturnsToTheHike() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openHikeDetail(in: app, titled: Self.hikeTitle)
        openPlace(named: "Boathouse", in: app)

        scrollToTap(app.buttons["hike-place-remove"], in: app)
        // By identifier: the button that asked carries the same words.
        let confirm = app.buttons["hike-place-remove-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: UITestTimeout.existence))
        confirm.tap()

        XCTAssertTrue(
            app.navigationBars[Self.hikeTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "removing a place goes back to its hike, and no further"
        )
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Boathouse")).firstMatch
                .waitForNonExistence(timeout: UITestTimeout.navigation)
        )
    }

    @MainActor
    func testPlacePinsOutliveHistoryAndHideBehindTheirSwitch() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openHikeDetail(in: app, titled: Self.hikeTitle)
        let pin = element("hike-place", in: app)
        XCTAssertTrue(pin.waitForExistence(timeout: UITestTimeout.navigation), "a saved hike's places stand on the map")

        app.segmentedControls["walk-segment"].buttons["History"].tap()
        XCTAssertTrue(element("walk-history-empty", in: app).waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(pin.exists, "reading the hike's history keeps its places on the map")

        app.segmentedControls["walk-segment"].buttons["Details"].tap()
        let toggle = app.switches["hike-place-pins-toggle"]
        scrollToTap(toggle, in: app)
        XCTAssertTrue(pin.waitForNonExistence(timeout: UITestTimeout.existence), "switched off, the pins leave the map")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Boathouse")).firstMatch.exists,
            "and the places stay on the hike"
        )

        scrollToTap(toggle, in: app)
        XCTAssertTrue(pin.waitForExistence(timeout: UITestTimeout.existence), "switched back on, they return")
    }
}
