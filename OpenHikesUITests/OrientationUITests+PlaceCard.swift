//
//  OrientationUITests+PlaceCard.swift
//  OpenHikesUITests
//
//  A place's card with the phone on its side: every row of it can be reached.
//
//  A phone held sideways gives the card the least height it ever has, and the
//  card scrolls only at its largest detent. Measured on iOS 18.6 and 27, the
//  sheet keeps its detents there: it opens at the smallest, one swipe takes
//  it to the window's full height, which is the largest, and the next one
//  scrolls. A compact height that stopped honouring them would leave the card
//  at full height with its remembered detent short of the largest, unable to
//  scroll. See `PlaceCardScroll`.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    /// The seeded place with the most to say: two facts above its location,
    /// so its card is taller than a phone held sideways.
    private static let placeWithFacts = "Lakeshore Hut"
    /// Swipes the card gets to bring its last row up: one to grow the sheet,
    /// one to scroll it, and one to spare.
    private static let cardSwipes = 3

    @MainActor
    func testALandscapePlaceCardScrollsToItsLastRow() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-import-gpx=\(PlaceFixture.gpxName)",
            "--ui-test-trail-points=seeded",
        ])
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        scrollToTap(element("hike-place-search", in: app), in: app)

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.placeWithFacts)).firstMatch
        scrollToTap(row, in: app)
        let card = element("places-around-card", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: UITestTimeout.navigation), "the row opens the place's card")
        XCTAssertEqual(element("places-around-card-title", in: app).label, Self.placeWithFacts)
        let lastRow = element("trail-place-osm-link", in: app)
        XCTAssertTrue(lastRow.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertFalse(isReachable(lastRow, in: app), "precondition: the card is taller than the landscape window")

        for _ in 0..<Self.cardSwipes where !isReachable(lastRow, in: app) {
            card.swipeUp()
        }
        XCTAssertTrue(isReachable(lastRow, in: app), "the card scrolls to its last row in landscape")
    }
}
