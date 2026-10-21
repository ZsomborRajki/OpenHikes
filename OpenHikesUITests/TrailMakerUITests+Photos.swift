//
//  TrailMakerUITests+Photos.swift
//  OpenHikesUITests
//
//  The Wikimedia Commons photographs *Search this area* finds in the maker:
//  the thumbnails on the map, the card one opens, and *Add Stop* there.
//
//  `--ui-test-trail-points=seeded` is what gives the maker a place source and
//  a photo source that reach no network — see `SeededCommonsPhotoSource`,
//  which stands three photographs around the middle of whatever area is
//  searched. What is asserted here is what only a simulator knows: that a
//  thumbnail is a pin a finger can reach over the map sheet, that it opens
//  the card with the picture and its credit, and that the card's *Add Stop*
//  puts a point down. What a search finds, what the chip does and what a save
//  keeps are `TrailDraftPhotosTests` and `TrailDraftPhotoControllerTests`.
//  The refused-copy scenario also drives Try Again and Skip from the saved
//  hike, through the map sheet's real alert presenter.
//

import XCTest

extension TrailMakerUITests {
    /// How many double taps the map may need before it is narrow enough.
    private static let photoSearchZoomSteps = 6
    private static let secondPhotoStop = CGVector(dx: 0.75, dy: 0.25)

    @MainActor
    func testAPhotoFromSearchThisAreaBecomesAStop() {
        // A hike imported first, so the map opens framed on a few kilometres
        // of trail rather than a country — the pill asks nothing past ten.
        let app = launchApp(
            arguments: [
                "--ui-test-trail-points=seeded",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        _ = openSeededPhoto(in: app)

        XCTAssertTrue(
            element("trail-place-photo", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a photograph's card should be headed by the photograph"
        )
        XCTAssertTrue(
            element("photo-licence-credit", in: app).exists,
            "and credit who took it, as every Commons photograph is"
        )
        XCTAssertFalse(
            element("trail-place-remove", in: app).exists,
            "a photograph is taken off the map by its chip, not from its card"
        )

        tapInPlaceSheet("trail-place-add-stop", in: app)
        XCTAssertTrue(
            element("trail-draft-point-1", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "Add Stop should put a point down where the camera stood"
        )
    }

    @MainActor
    func testMissedPhotosCanBeRetriedAndSkipped() {
        let app = launchApp(arguments: [
            "--ui-test-trail-points=seeded",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-refuse-trail-photo-copy",
        ])
        let map = openSeededPhoto(in: app)
        tapInPlaceSheet("trail-place-add-stop", in: app)
        // The photograph is one end, so the saved line necessarily passes it.
        dropPin(at: Self.secondPhotoStop, on: map)
        tapInPlaceSheet("trail-place-add-stop", in: app)
        XCTAssertTrue(element("trail-draft-point-2", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        element("trail-draft-save", in: app).tap()
        let name = "Photo Retry Trail"
        nameTheTrail(name, in: app)

        let alert = app.alerts["Photos Not Added"]
        for _ in 0..<2 {
            XCTAssertTrue(alert.waitForExistence(timeout: UITestTimeout.navigation))
            let namedMessage = alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(namedMessage.exists)
            alert.buttons["Try Again"].tap()
        }
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "a refused retry must be offered again"
        )
        alert.buttons["Skip"].tap()
        XCTAssertTrue(waitUntil { !alert.exists }, "Skip should close the failure notice")
        XCTAssertTrue(element("map-sheet", in: app).exists, "the map sheet must survive the alert")
        XCTAssertTrue(app.navigationBars[name].exists, "the trail itself must still be saved")
        popScreen(in: app)
        XCTAssertTrue(awaitHikeRow(titled: name, in: app).exists)
    }

    @MainActor
    private func openSeededPhoto(in app: XCUIApplication) -> XCUIElement {
        _ = awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))
        openTrailMaker(in: app)

        let pill = element("trail-draft-search-this-area", in: app)
        XCTAssertTrue(
            pill.waitForExistence(timeout: UITestTimeout.navigation),
            "the maker should offer Search this area with a place source"
        )
        // Zoomed in further only if the framing left the map too wide, with
        // MapKit's own double tap, which zooms and does not turn the map.
        for _ in 0..<Self.photoSearchZoomSteps where !waitUntil(timeout: UITestTimeout.brief, { pill.isEnabled }) {
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).doubleTap()
        }
        XCTAssertTrue(waitUntil { pill.isEnabled }, "the map should be narrow enough to search")
        pill.tap()

        let photo = element("trail-draft-photo-pin", in: app)
        XCTAssertTrue(
            photo.waitForExistence(timeout: UITestTimeout.navigation),
            "the search should put the area's photographs on the map"
        )
        photo.tap()
        XCTAssertTrue(
            element("trail-place-photo", in: app).waitForExistence(timeout: UITestTimeout.navigation)
        )
        return map
    }
}
