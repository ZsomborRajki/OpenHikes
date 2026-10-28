//
//  OrientationUITests+PlacesAround.swift
//  OpenHikesUITests
//
//  *Places Around Trail* and *Places Nearby* through a turn of the phone: the
//  card open over either stays open, both ways round, and *Places Around
//  Trail*'s list keeps what the hiker chose.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    /// A seeded place the line passes, so *Places Around Trail* lists it
    /// whatever *Within* says, and one ``SeededTrailPointSource`` hands
    /// *Places Nearby* wherever it asks.
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

        openCard(on: Self.placeOnTheLine, in: app)
        turnBothWays(keepingTheCardOn: Self.placeOnTheLine, in: app)

        closeCard(in: app)
        XCTAssertTrue(onTrail.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(onTrail.isSelected, "Within is still On Trail")
        XCTAssertFalse(nearby.exists, "and the list still leaves out what is near")
    }

    /// The same for *Places Nearby*, over a walk being recorded, which held
    /// what it had found as its own state too.
    @MainActor
    func testPlacesNearbyKeepsItsCardThroughRotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp(arguments: ["--ui-test-enable-location", "--ui-test-trail-points=seeded"])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }
        launch(app)
        XCTAssertTrue(waitForPortrait(app), "the app should have started upright")

        startRecording(in: app)
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence), "precondition: the walk has a fix")
        walkRecordedTrace([UITestFixture.trailheadCoordinate], countedBy: points)
        tapWhenReady(element("recording-places-nearby", in: app))
        let list = element("places-nearby-list", in: app)
        XCTAssertTrue(list.waitForExistence(timeout: UITestTimeout.navigation), "precondition: the area is asked about")

        openCard(on: Self.placeOnTheLine, in: app)
        turnBothWays(keepingTheCardOn: Self.placeOnTheLine, in: app)

        closeCard(in: app)
        XCTAssertTrue(list.exists, "over the same list")
    }

    // MARK: - The card

    @MainActor
    private func openCard(on place: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", place)).firstMatch
        scrollToTap(row, in: app)
        let title = element("places-around-card-title", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "precondition: the row opens a card")
    }

    /// Turns the phone on its side and back, with the card on `place` open
    /// after each turn.
    @MainActor
    private func turnBothWays(keepingTheCardOn place: String, in app: XCUIApplication) {
        let title = element("places-around-card-title", in: app)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(orientation == .portrait ? waitForPortrait(app) : waitForLandscape(app))
            XCTAssertTrue(title.waitForExistence(timeout: UITestTimeout.navigation), "the card is still open")
            XCTAssertEqual(title.label, place, "on the same place")
        }
    }

    /// Closes the card, which shows it still takes touches.
    @MainActor
    private func closeCard(in app: XCUIApplication) {
        let close = app.buttons["places-around-card-close"]
        XCTAssertTrue(close.waitForExistence(timeout: UITestTimeout.existence))
        close.tap()
        let title = element("places-around-card-title", in: app)
        XCTAssertTrue(title.waitForNonExistence(timeout: UITestTimeout.existence), "the card takes touches")
    }
}
