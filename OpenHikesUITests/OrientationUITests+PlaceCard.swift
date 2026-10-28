//
//  OrientationUITests+PlaceCard.swift
//  OpenHikesUITests
//
//  A place's card with the phone on its side: every row of it can be reached.
//
//  A phone held sideways gives the card the least height it ever has, and the
//  card scrolls only at its largest detent. Measured on iOS 18.6 and 27, the
//  sheet keeps its detents there, all but `.medium`, which is inactive at a
//  compact height: the card asks for it and opens at the smallest instead, one
//  swipe takes it to the window's full height, which is the largest, and the
//  next one scrolls. A compact height that stopped honouring them would leave
//  the card at full height with its remembered detent short of the largest,
//  unable to scroll. See `PlaceCardScroll`.
//
//  The card is held against the window only once it has the window's full
//  height. At the smallest detent no card reaches its last row, so a row out
//  of reach there says nothing about this one, and a card that fitted the
//  window would pass without being scrolled once.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    /// The seeded place with the most to say: two facts above its location,
    /// so its card is taller than a phone held sideways — if only just: at
    /// full height its last row's middle is a few points below the window. A
    /// card a few points shorter fails the precondition below, and needs more
    /// to say before this test means anything again.
    private static let placeWithFacts = "Lakeshore Hut"
    /// Swipes the card at full height gets to bring its last row up: one to
    /// scroll it, and one to spare.
    private static let cardSwipes = 2
    /// How far down the window a card at full height may start, as a share of
    /// the window's height. Measured, it starts at the window's top edge, and
    /// at its smallest detent nearly three quarters of the way down, with no
    /// detent between them at a compact height.
    private static let fullHeightTopShare: CGFloat = 0.1

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

        card.swipeUp()
        XCTAssertTrue(
            waitUntil { isAtFullHeight(card, in: app) },
            "one swipe takes the card from its smallest detent to the window's full height"
        )
        XCTAssertFalse(isReachable(lastRow, in: app), "precondition: the card is taller than the landscape window")

        for _ in 0..<Self.cardSwipes where !isReachable(lastRow, in: app) {
            card.swipeUp()
        }
        XCTAssertTrue(isReachable(lastRow, in: app), "the card scrolls to its last row in landscape")
    }

    /// Whether the card starts at the top of the window, where at a compact
    /// height only its largest detent puts it.
    @MainActor
    private func isAtFullHeight(_ card: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = windowFrame(of: app)
        return card.frame.minY - window.minY < window.height * Self.fullHeightTopShare
    }
}
