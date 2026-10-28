//
//  OrientationUITests+PlaceSearch.swift
//  OpenHikesUITests
//
//  The two place searches keep the card they have open when the sheet's
//  portrait host gives way to the landscape panel. The window itself must
//  turn before the assertion: a still-present card in the old host proves
//  nothing about the replacement.
//

import XCTest

extension OrientationUITests {
    @MainActor
    func testPlacesAroundKeepsItsCardThroughRotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-import-gpx=\(PlaceFixture.gpxName)",
            "--ui-test-trail-points=seeded",
        ])
        openHikeDetail(in: app, titled: PlaceFixture.hikeTitle)
        scrollToTap(element("hike-place-search", in: app), in: app)
        XCTAssertTrue(element("places-around-nearby", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        let reach = app.segmentedControls["places-around-reach"].buttons.element(boundBy: 1)
        reach.tap()
        XCTAssertTrue(reach.isSelected)
        openSearchCard(named: "Thumsee Kopf", in: app)

        guard assertSearchCardSurvivesTurns(in: app, titled: "Thumsee Kopf") else { return }

        tapWhenReady(app.buttons["places-around-card-close"])
        XCTAssertTrue(reach.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(reach.isSelected, "the search also keeps the chosen reach")
    }

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
        startRecording(in: app)
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        walkRecordedTrace([UITestFixture.trailheadCoordinate], countedBy: points)
        tapWhenReady(element("recording-places-nearby", in: app))
        XCTAssertTrue(element("places-nearby-list", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        openSearchCard(named: "Lakeshore Hut", in: app)

        guard assertSearchCardSurvivesTurns(in: app, titled: "Lakeshore Hut") else { return }
    }

    @MainActor
    private func openSearchCard(named title: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        scrollToTap(row, in: app)
        XCTAssertTrue(element("places-around-card", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertEqual(element("places-around-card-title", in: app).label, title)
    }

    @MainActor
    private func assertSearchCardSurvivesTurns(in app: XCUIApplication, titled title: String) -> Bool {
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(
                waitUntil(timeout: UITestTimeout.navigation) {
                    let window = app.windows.firstMatch.frame
                    return orientation == .portrait ? window.height > window.width : window.width > window.height
                },
                "the window must actually turn while the card is open"
            )
            let card = element("places-around-card", in: app)
            guard card.waitForExistence(timeout: UITestTimeout.navigation) else {
                XCTFail("turning the window must keep the same place's card open")
                return false
            }
            XCTAssertEqual(element("places-around-card-title", in: app).label, title)
        }
        return true
    }
}
