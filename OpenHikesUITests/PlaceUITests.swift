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
//  And *Add Place* from the map's pill: a form with a pin standing where the
//  place will go, which puts nothing on the hike until *Add*.
//

import XCTest

nonisolated final class PlaceUITests: XCTestCase {
    private static let fixture = PlaceFixture.gpxName
    private static let hikeTitle = PlaceFixture.hikeTitle

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

    // MARK: - Add Place, from the pill

    @MainActor
    func testAddingAPlaceFromThePill() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openPlaceAdder(in: app)

        XCTAssertEqual(element("hike-place-adder-title", in: app).label, "Viewpoint")
        XCTAssertEqual(app.textFields["hike-place-adder-name"].value as? String, "Viewpoint")
        XCTAssertTrue(element("hike-place-placeholder", in: app).exists, "a pin stands where the place will go")
        XCTAssertTrue(element("hike-place-adder-camera", in: app).exists)
        XCTAssertTrue(element("hike-place-adder-library", in: app).exists)
        // Nothing to share, remove or find on the map: it is not a place yet.
        XCTAssertFalse(element("hike-place-share", in: app).exists)
        XCTAssertFalse(element("hike-place-remove", in: app).exists)
        XCTAssertFalse(element("hike-place-show-on-map", in: app).exists)
        XCTAssertFalse(element("map-add-place-button", in: app).exists, "the pill steps aside for the form")

        app.buttons["hike-place-adder-add"].tap()

        let title = element("hike-place-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "adding opens the new place")
        XCTAssertEqual(title.label, "Viewpoint")
        XCTAssertTrue(app.buttons["hike-place-edit"].exists, "it is the hiker's own")
        popScreen(in: app)
        XCTAssertTrue(
            app.navigationBars[Self.hikeTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "back from the new place is the hike, not the spent form"
        )
    }

    /// What the form is told reaches the place it adds. The name, the kind and
    /// the note are each a view of their own making its own binding — see
    /// `HikePlaceAdder` — so each is followed here from its field to the new
    /// place: a name the title follows as it is typed, and which a kind picked
    /// after it leaves alone, the kind, and a note.
    @MainActor
    func testTheFormsAnswersReachTheNewPlace() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openPlaceAdder(in: app)
        let name = app.textFields["hike-place-adder-name"]

        XCTAssertTrue(replaceText(of: name, with: "Lookout"), "precondition: a name is typed")
        let title = element("hike-place-adder-title", in: app)
        XCTAssertTrue(waitUntil { title.label == "Lookout" }, "the title follows the name")
        submitKeyboardEdit(in: app)

        scrollToTap(element("trail-place-kind-picker", in: app), in: app)
        tapWhenReady(app.buttons["Summit"].firstMatch)
        XCTAssertEqual(name.value as? String, "Lookout", "a kind picked after a typed name leaves the name alone")

        let note = element("hike-place-adder-note", in: app)
        scrollToTap(note, in: app)
        note.typeText("Best at dawn")
        app.buttons["hike-place-adder-add"].tap()

        let placeTitle = element("hike-place-title", in: app)
        XCTAssertTrue(placeTitle.waitForExistence(timeout: UITestTimeout.navigation), "adding opens the new place")
        XCTAssertEqual(placeTitle.label, "Lookout")
        XCTAssertEqual(element("hike-place-note", in: app).label, "Best at dawn")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Summit")).firstMatch.exists,
            "the card names the kind under the name"
        )
    }

    /// The pin stays in the middle of the map and the map moves under it:
    /// wherever the map is left is where the place goes. See
    /// `MapPlacePlacement.swift`.
    @MainActor
    func testMovingTheMapMovesTheNewPlace() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openPlaceAdder(in: app)
        let coordinates = element("trail-place-coordinates", in: app)
        XCTAssertTrue(coordinates.waitForExistence(timeout: UITestTimeout.existence))
        let opened = reading(of: coordinates)

        panPlaceMap(in: app)

        let moved = NSPredicate { _, _ in self.reading(of: coordinates) != opened }
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation(for: moved, evaluatedWith: nil)], timeout: UITestTimeout.existence),
            .completed,
            "the form's coordinates follow the map"
        )
        XCTAssertTrue(element("hike-place-placeholder", in: app).exists, "the pin stays up while the map moves")
        let placed = reading(of: coordinates)

        app.buttons["hike-place-adder-add"].tap()
        XCTAssertTrue(
            element("hike-place-title", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "adding opens the new place"
        )
        XCTAssertEqual(
            reading(of: element("trail-place-coordinates", in: app)),
            placed,
            "the place went where the pin was left, not where the form opened"
        )
    }

    @MainActor
    func testCancellingAddPlaceLeavesNothingBehind() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=\(Self.fixture)"])
        openPlaceAdder(in: app)
        let placeholder = element("hike-place-placeholder", in: app)
        XCTAssertTrue(placeholder.exists)

        app.buttons["hike-place-adder-cancel"].tap()

        XCTAssertTrue(app.navigationBars[Self.hikeTitle].waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: UITestTimeout.existence), "the pin goes with the form")
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Viewpoint")).firstMatch.exists,
            "and no place was added"
        )
    }
}
