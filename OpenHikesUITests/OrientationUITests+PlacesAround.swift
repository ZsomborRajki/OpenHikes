//
//  OrientationUITests+PlacesAround.swift
//  OpenHikesUITests
//
//  *Places Around Trail* through a turn of the phone: the card open over it
//  stays open, both ways round, and the list keeps what the hiker chose.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    /// A seeded place the line passes, so it is listed whatever *Within* says.
    private static let placeOnTheLine = "Lakeshore Hut"

    /// Turning the phone with a place's card open leaves the card open on
    /// the same place, and *Within* as it was set.
    ///
    /// The screen is drawn in the sheet in portrait and in the side panel in
    /// landscape, so a turn builds it again. While what it had found was its
    /// own state, the card closed, *Within* went back to its widest, and the
    /// summit off the line came back under *Nearby*.
    @MainActor
    func testPlacesAroundKeepsItsCardAndWithinThroughRotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-import-gpx=\(PlaceFixture.gpxName)",
            "--ui-test-trail-points=seeded",
        ])
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        scrollToTap(element("hike-place-search", in: app), in: app)
        let nearby = element("places-around-nearby", in: app)
        XCTAssertTrue(nearby.waitForExistence(timeout: UITestTimeout.navigation), "precondition: a place is Nearby")
        let onTrail = app.segmentedControls["places-around-reach"].buttons["On Trail"]
        onTrail.tap()
        XCTAssertTrue(nearby.waitForNonExistence(timeout: UITestTimeout.existence), "precondition: On Trail drops it")

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.placeOnTheLine)).firstMatch
        scrollToTap(row, in: app)
        let title = element("places-around-card-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "precondition: the row opens a card")

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(orientation == .portrait ? waitForPortrait(app) : waitForLandscape(app))
            XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "the card is still open")
            XCTAssertEqual(title.label, Self.placeOnTheLine, "on the same place")
        }

        let close = app.buttons["places-around-card-close"]
        XCTAssertTrue(close.waitForExistence(timeout: UITestTimeout.existence))
        close.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: UITestTimeout.existence), "the card takes touches")
        XCTAssertTrue(onTrail.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(onTrail.isSelected, "Within is still On Trail")
        XCTAssertFalse(nearby.exists, "and the list still leaves out what is near")
    }
}
