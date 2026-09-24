//
//  PlaceSupport.swift
//  OpenHikesUITests
//
//  The way onto a saved hike's place screens, for the two suites that go
//  there.
//
//  Its own file for the reason `TrailMakerSupport.swift` is one: rather than a
//  copy in each suite. ``PlaceUITests`` is what presses the buttons on these
//  screens; ``AccessibilityUITests`` needs only the way in.
//

import XCTest

/// The Thumsee loop with two `<wpt>`s on it: a boathouse the file describes
/// itself, which is the hiker's own place, and a spring carrying an
/// openstreetmap.org link, which is OpenStreetMap's.
nonisolated enum PlaceFixture {
    static let gpxName = "ThumseeLoopPlaces"
    static let hikeTitle = "Thumsee Loop (places)"
    static let ownPlace = "Boathouse"
    static let mappedPlace = "Thumsee Spring"
}

extension XCTestCase {
    /// Opens one of the open hike's places from its row under *Places*.
    @MainActor
    func openPlace(named name: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        scrollToTap(row, in: app)
        let title = element("hike-place-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "a place row should open its screen")
        XCTAssertEqual(title.label, name)
    }

    /// Opens the fixture hike and *Add Place* from the map's pill.
    @MainActor
    func openPlaceAdder(in app: XCUIApplication) {
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        let addPlace = element("map-add-place-button", in: app)
        XCTAssertTrue(addPlace.waitForExistence(timeout: UITestTimeout.navigation), "a hike's screen offers Add Place")
        addPlace.tap()
        XCTAssertTrue(
            element("hike-place-adder-title", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the pill opens the form"
        )
    }
}
