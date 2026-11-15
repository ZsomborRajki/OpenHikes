//
//  MapModesUITests.swift
//  OpenHikesUITests
//
//  *Map Modes*: that the pill on the map opens it, that a card chosen there
//  is the map drawn behind it, and that it can present at all — the sheet is
//  attached inside the map sheet's contents, and a locked card presents the
//  paywall from inside that again.
//
//  None of it is a state a unit test can reach. Which view a presentation is
//  attached to is resolved only by a running app, as `MapScreenAlertUITests`
//  says of the alerts.
//

import XCTest

nonisolated final class MapModesUITests: XCTestCase {
    /// The whole trip: open, choose, see the map behind change, close, and
    /// find the choice held.
    ///
    /// The map's own credit line is the witness that the map changed. It
    /// credits the raster map's providers and the routes over it, and MapKit
    /// draws its own for Apple's, so with the routes off it is there over
    /// OpenStreetMap and gone over Apple Maps.
    @MainActor
    func testChoosingAMapChangesTheMapBehindTheSheet() {
        let app = launchApp()
        XCTAssertEqual(
            element("map-modes-button", in: app).label,
            "Map Modes",
            "a glyph is not a label, so the button names what it opens"
        )
        let credit = element("map-attribution", in: app)
        XCTAssertTrue(
            credit.waitForExistence(timeout: UITestTimeout.navigation),
            "OpenStreetMap, the default, is credited on the map"
        )

        openMapModes(in: app)
        let openStreetMap = element("provider-row-osm", in: app)
        XCTAssertTrue(openStreetMap.isSelected, "the map being drawn should be the selected card")
        // The routes are OpenStreetMap's and credited over any map, Apple's
        // included, so the line tells the two maps apart only without them.
        let clean = element("hiking-routes-off", in: app)
        clean.tap()
        XCTAssertTrue(waitUntilSelected(clean), "the clean map should become the chosen picture")
        XCTAssertTrue(
            element("tile-attribution", in: app).exists,
            "the cards' credits should stand along the foot of the sheet"
        )

        let appleMaps = element("provider-row-apple_maps", in: app)
        appleMaps.tap()
        XCTAssertTrue(waitUntilSelected(appleMaps), "the tapped map should become the selected one")
        XCTAssertFalse(openStreetMap.isSelected)
        XCTAssertTrue(
            waitUntil { !credit.exists },
            "the map behind the sheet should be Apple's by now, which draws its own credit"
        )

        closeMapModes(in: app)
        XCTAssertTrue(
            element("map-sheet", in: app).exists,
            "closing Map Modes should leave the map sheet up"
        )

        openMapModes(in: app)
        XCTAssertTrue(
            element("provider-row-apple_maps", in: app).isSelected,
            "the choice should hold once the sheet has been closed and opened again"
        )
    }

    /// A sheet stays a sheet with the phone on its side, where one left to
    /// adapt would cover the map it is choosing.
    ///
    /// The map may show above the sheet or beside it. A phone on its side
    /// draws the sheet as a card in the middle of the bottom edge, and a
    /// card taller than the window — a build without API keys adds two
    /// notes — reaches its top, with the map still on either side of it.
    @MainActor
    func testMapModesLeavesTheMapInViewInLandscape() {
        let app = launchApp()
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))

        openMapModes(in: app)
        let window = windowFrame(of: app)
        let title = element("map-modes-title", in: app).frame
        let close = element("map-modes-close", in: app).frame
        let mapAbove = title.minY > window.minY + window.height * Self.leastMapShare
        let mapBeside = close.maxX < window.maxX - window.width * Self.leastMapShare
        XCTAssertTrue(
            mapAbove || mapBeside,
            "the sheet should leave the map in view above it or beside it — title \(title), ✕ \(close), "
                + "window \(window)"
        )
        closeMapModes(in: app)
    }

    /// A paid map's card opens the paywall rather than selecting, from a
    /// sheet that is itself presented from inside the map sheet.
    ///
    /// Skipped in a build without `OpenHikes/Secrets.plist`, where the card
    /// is disabled outright and the paywall's route is the About row — see
    /// `SettingsUITests.testProIsReachableWithoutTheMapTilesSection`. The
    /// card's value says so before anything is tapped, and is read first:
    /// whether a disabled card reports itself disabled is the audit's
    /// business, not this skip's.
    @MainActor
    func testALockedMapOpensThePaywall() throws {
        let app = launchApp()
        openMapModes(in: app)

        let paid = element("provider-row-stadia_outdoors", in: app)
        XCTAssertTrue(paid.waitForExistence(timeout: UITestTimeout.navigation))
        try XCTSkipIf(
            (paid.value as? String) == "Needs API key",
            "a paid map's card is disabled in a build with no API key for it"
        )
        // A paid card is also disabled while StoreKit has not answered.
        XCTAssertTrue(waitUntil { paid.isEnabled }, "the paid card should be enabled once StoreKit has answered")
        paid.tap()

        XCTAssertTrue(
            element("map-paywall", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a locked card should open the paywall"
        )
    }

    /// *Hiking Routes*, as two pictures under the cards: the routes are
    /// chosen at first, and the clean map takes them off the map behind the
    /// sheet, held once the sheet is closed and opened again.
    ///
    /// Over Apple's map the map's credit line is the witness: the layer is
    /// OpenStreetMap's routes, so the line names OpenStreetMap there only
    /// while the layer is drawn. A launch for UI tests fetches no squares, so
    /// the routes themselves never show.
    @MainActor
    func testHikingRoutesPicturesSwitchTheLayer() {
        let app = launchApp()
        openMapModes(in: app)
        let apple = element("provider-row-apple_maps", in: app)
        XCTAssertTrue(apple.waitForExistence(timeout: UITestTimeout.navigation))
        apple.tap()
        XCTAssertTrue(waitUntilSelected(apple), "the tapped map should become the selected one")

        let clean = element("hiking-routes-off", in: app)
        let routes = element("hiking-routes-on", in: app)
        XCTAssertTrue(routes.isSelected, "the routes are on until they are switched off")
        XCTAssertFalse(clean.isSelected)
        XCTAssertEqual(routes.label, "Hiking Routes")
        let credit = element("map-attribution", in: app)
        XCTAssertTrue(
            waitUntil { credit.exists && credit.label.contains("OpenStreetMap") },
            "over Apple's map, the line should credit the routes drawn over it"
        )

        clean.tap()
        XCTAssertTrue(waitUntilSelected(clean), "the tapped picture should become the chosen one")
        XCTAssertFalse(routes.isSelected)
        XCTAssertTrue(
            waitUntil { !credit.exists },
            "with the routes off, Apple's map owes its line nothing"
        )

        closeMapModes(in: app)
        openMapModes(in: app)
        XCTAssertTrue(
            element("hiking-routes-off", in: app).isSelected,
            "the choice should hold once the sheet has been closed and opened again"
        )
    }

    /// How much of the window the map has to keep, as a share of its height
    /// above the sheet or of its width beside it, to count as in view.
    private static let leastMapShare: CGFloat = 0.1

    /// A place card leaves the map live behind it, the pill included, and
    /// the map sheet is already presenting the card. *Map Modes* asked for
    /// from under it used to wait, and come up when the card was closed.
    @MainActor
    func testMapModesOpensOverAPlaceCard() {
        let app = launchApp(arguments: Self.placeArguments)
        let card = openFoundPlaceCard(in: app)

        openMapModes(in: app)
        closeMapModes(in: app)
        XCTAssertTrue(card.exists, "the card should still be up under it")

        app.buttons["places-around-card-close"].tap()
        XCTAssertTrue(waitUntil { !card.exists })
        // A sheet that had queued behind the card comes up only once the
        // card has finished going, so this waits out that much.
        XCTAssertFalse(
            element("map-modes-title", in: app).waitForExistence(timeout: UITestTimeout.brief),
            "closing the card should bring nothing back"
        )
    }

    /// The trail maker's place card is the other card that leaves the map
    /// live, and presents *Map Modes* over itself the same way.
    @MainActor
    func testMapModesOpensOverTheMakersPlaceCard() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))
        openTrailMaker(in: app)
        dropPin(at: Self.pinSpot, on: map)
        let card = element("trail-place-sheet", in: app)
        XCTAssertTrue(
            card.waitForExistence(timeout: UITestTimeout.navigation),
            "a press on the map should open the place card"
        )

        openMapModes(in: app)
        closeMapModes(in: app)
        XCTAssertTrue(card.exists, "the card should still be up under it")
    }

    /// Which sheet presents *Map Modes* follows the cards' own appearing and
    /// going. A card taken through a turn of the phone and closed must leave
    /// the map sheet the presenter again, or the pill opens nothing.
    @MainActor
    func testMapModesOpensAfterACardWentThroughARotation() {
        let app = launchApp(arguments: Self.placeArguments)
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let card = openFoundPlaceCard(in: app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        XCTAssertTrue(card.waitForExistence(timeout: UITestTimeout.navigation), "the card should survive the turn")
        app.buttons["places-around-card-close"].tap()
        XCTAssertTrue(waitUntil { !card.exists })

        openMapModes(in: app)
        closeMapModes(in: app)
    }

    /// A hike with mapped places around it, for the cards above.
    private static let placeArguments = [
        "--ui-test-import-gpx=\(PlaceFixture.gpxName)",
        "--ui-test-trail-points=seeded",
    ]

    /// Where a press drops the maker's pin: high on the map, clear of the
    /// sheet and of the controls along the map's edges.
    private static let pinSpot = CGVector(dx: 0.5, dy: 0.25)

    /// Opens the hike, searches around it, and opens a found place's card.
    @MainActor
    private func openFoundPlaceCard(in app: XCUIApplication) -> XCUIElement {
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        scrollToTap(element("hike-place-search", in: app), in: app)
        XCTAssertTrue(
            element("places-around-nearby", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the search should have answered before a place is opened"
        )
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thumsee Kopf")).firstMatch
        scrollToTap(row, in: app)
        let card = element("places-around-card-title", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: UITestTimeout.navigation), "a found place's row opens its card")
        return card
    }
}
