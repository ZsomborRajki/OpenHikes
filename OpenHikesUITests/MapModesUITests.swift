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
    /// credits the raster map's providers, and MapKit draws its own for
    /// Apple's, so it is there over OpenStreetMap and gone over Apple Maps.
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
        let title = element("map-modes-title", in: app)
        XCTAssertGreaterThan(
            title.frame.minY,
            window.minY + window.height * Self.leastMapShare,
            "the sheet should stand at the foot of the window, with the map above it"
        )
        closeMapModes(in: app)
    }

    /// A paid map's card opens the paywall rather than selecting, from a
    /// sheet that is itself presented from inside the map sheet.
    ///
    /// Skipped in a build without `OpenHikes/Secrets.plist`, where the card
    /// is disabled outright and the paywall's route is the About row — see
    /// `SettingsUITests.testProIsReachableWithoutTheMapTilesSection`.
    @MainActor
    func testALockedMapOpensThePaywall() throws {
        let app = launchApp()
        openMapModes(in: app)

        let paid = element("provider-row-stadia_outdoors", in: app)
        XCTAssertTrue(paid.waitForExistence(timeout: UITestTimeout.navigation))
        try XCTSkipUnless(
            waitUntil { paid.isEnabled },
            "a paid map's card is disabled in a build with no API key for it"
        )
        paid.tap()

        XCTAssertTrue(
            element("map-paywall", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a locked card should open the paywall"
        )
    }

    /// How far down the window the sheet's title has to stand, as a share of
    /// its height, for the map to count as in view above it.
    private static let leastMapShare: CGFloat = 0.1

    /// A place card leaves the map live behind it, the pill included, and
    /// the map sheet is already presenting the card. *Map Modes* asked for
    /// from under it used to wait, and come up when the card was closed.
    @MainActor
    func testMapModesOpensOverAPlaceCard() {
        let app = launchApp(
            arguments: [
                "--ui-test-import-gpx=\(PlaceFixture.gpxName)",
                "--ui-test-trail-points=seeded",
            ]
        )
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

        openMapModes(in: app)
        closeMapModes(in: app)
        XCTAssertTrue(card.exists, "the card should still be up under it")

        app.buttons["places-around-card-close"].tap()
        XCTAssertTrue(waitUntil { !card.exists })
        XCTAssertFalse(
            element("map-modes-title", in: app).exists,
            "closing the card should bring nothing back"
        )
    }
}
