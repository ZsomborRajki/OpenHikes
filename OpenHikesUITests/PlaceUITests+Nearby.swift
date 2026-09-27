//
//  PlaceUITests+Nearby.swift
//  OpenHikesUITests
//
//  *Places Nearby*: what OpenStreetMap has around a walk being recorded,
//  asked about as the screen opens, and added to the recording one at a time.
//
//  Against ``SeededTrailPointSource``, which answers the same four places
//  whatever area is asked — so this is about the screen, not the geometry
//  ``PlacesNearbyFrame`` decides, which `PlacesNearbyTests` covers.
//

import XCTest

extension PlaceUITests {
    private static let nearbyHut = "Lakeshore Hut"

    @MainActor
    func testPlacesNearbyAddsAPlaceToTheRecording() {
        let app = makeApp(
            arguments: [
                "--ui-test-enable-location",
                "--ui-test-trail-points=seeded",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                points.exists && (points.value as? String).map { $0 != "0" } == true
            },
            "the walk needs a fix for the screen to frame"
        )

        tapWhenReady(element("recording-places-nearby", in: app))
        XCTAssertTrue(
            element("places-nearby-list", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "opening asks about the area around the walk, with no tap on the map"
        )
        XCTAssertFalse(app.segmentedControls["places-around-reach"].exists, "and there is no Within to choose")

        let add = app.buttons["Add \(Self.nearbyHut)"]
        scrollToTap(add, in: app)
        XCTAssertTrue(add.waitForNonExistence(timeout: UITestTimeout.existence), "adding is immediate")

        popScreen(in: app)
        XCTAssertTrue(app.navigationBars["Record Hike"].waitForExistence(timeout: UITestTimeout.navigation))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.nearbyHut)).firstMatch
        scrollIntoView(row, in: app)
        XCTAssertTrue(row.exists, "the recording keeps the place")
    }
}
