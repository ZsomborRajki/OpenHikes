//
//  PlaceSupport.swift
//  OpenHikesUITests
//
//  The way onto a saved hike's place screens, for the suites that go there.
//
//  Its own file for the reason `TrailMakerSupport.swift` is one: rather than a
//  copy in each suite. ``PlaceUITests`` is what presses the buttons on these
//  screens; ``AccessibilityUITests`` needs only the way in, and the map's own
//  controls' suites need only a card up over the map.
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
    /// A summit *Places Around Trail* finds near the loop, from the seeded
    /// OpenStreetMap places.
    static let foundPlace = "Thumsee Kopf"

    /// The hike, with OpenStreetMap's places around it for
    /// ``XCTestCase/openFoundPlaceCard(in:)`` to find.
    static let aroundArguments = [
        "--ui-test-import-gpx=\(gpxName)",
        "--ui-test-trail-points=seeded",
    ]
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

    /// Opens the fixture hike, searches around it, and opens a found place's
    /// card: a sheet over the map sheet that leaves the map live behind it,
    /// the map's own controls included. For a launch with
    /// ``PlaceFixture/aroundArguments``.
    @MainActor
    @discardableResult func openFoundPlaceCard(in app: XCUIApplication) -> XCUIElement {
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        scrollToTap(element("hike-place-search", in: app), in: app)
        XCTAssertTrue(
            element("places-around-nearby", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the search should have answered before a place is opened"
        )
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", PlaceFixture.foundPlace)).firstMatch
        scrollToTap(row, in: app)
        let card = element("places-around-card-title", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: UITestTimeout.navigation), "a found place's row opens its card")
        return card
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

    /// Moves the map under *Add Place*'s fixed pin: a short press and a drag,
    /// which pans — a held one would drop a pin.
    @MainActor
    func panPlaceMap(in app: XCUIApplication) {
        let map = element("trail-map", in: app)
        map.coordinate(withNormalizedOffset: PlaceMapPan.from)
            .press(forDuration: PlaceMapPan.press, thenDragTo: map.coordinate(withNormalizedOffset: PlaceMapPan.to))
    }

    /// Everything a place's coordinates row says, whichever of its label and
    /// value carries the figures — what a pan is checked against.
    @MainActor
    func reading(of row: XCUIElement) -> String {
        "\(row.label) \(row.value as? String ?? "")"
    }
}

/// Up and to the left, clear of the sheet along the bottom.
nonisolated private enum PlaceMapPan {
    private static let startX = 0.5
    private static let startY = 0.2
    private static let endX = 0.3
    private static let endY = 0.1
    static let from = CGVector(dx: startX, dy: startY)
    static let to = CGVector(dx: endX, dy: endY)
    static let press: TimeInterval = 0.1
}
