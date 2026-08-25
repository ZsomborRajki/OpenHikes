//
//  PhotoUITests.swift
//  OpenHikesUITests
//
//  The photo pipeline, which is the part of the app automation can least
//  afford to skip and can least easily reach: the Simulator has no camera and
//  the library picker is a system process a test may not drive.
//
//  So two different fakes are used, and neither fakes the app. The picker
//  tests present the real system picker and assert only that it came up and
//  that leaving it left the sheet standing; the gallery tests seed images
//  through `--ui-test-seed-photos`, which writes them with the shipping
//  importer and reads them back with the shipping decode.
//

import XCTest

nonisolated final class PhotoUITests: XCTestCase {
    /// The camera pill's presentations have to hang off the sheet, not off the
    /// view that presents it.
    ///
    /// A view can only have one modal up at a time, and this app's sheet is
    /// never taken down — a `.photosPicker` attached beside it is silently
    /// never presented. The failure has no symptom other than a button that
    /// does nothing, which is exactly the kind of thing only automation
    /// catches. Cancelling again afterwards is the other half of it: the GPX
    /// importer taught this app that a picker dismissing can take the sheet
    /// with it.
    @MainActor
    func testOpensAndClosesThePhotoLibraryPickerOverTheSheet() {
        let app = launchApp(
            arguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )

        openHikeDetail(in: app)

        let library = element("map-photo-library-button", in: app)
        XCTAssertTrue(
            library.waitForExistence(timeout: UITestTimeout.navigation),
            "opening a hike should offer the pill the picker is reached from"
        )
        library.tap()

        // The picker is out of process, so its contents are not the app's to
        // assert on; its cancel button carries that identifier in every
        // locale, which is enough to know it is on screen.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(
            cancel.waitForExistence(timeout: UITestTimeout.existence),
            "tapping the library button should present the photo picker"
        )

        cancel.tap()
        XCTAssertTrue(
            element("map-sheet", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "dismissing the picker must leave the app's sheet standing"
        )
        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle].exists,
            "and must not pop the screen the pill was offered from"
        )
    }

    /// The photo gallery, seeded because the Simulator has no camera and the
    /// library picker is a system process automation may not drive.
    ///
    /// The bytes are written by the shipping importer and read back by the
    /// shipping decode, so what is faked is the pixels and nothing else. Both
    /// of the viewer's toolbar actions are checked: showing a photo on the map
    /// takes the user out to it, and deleting the last one closes a viewer
    /// with nothing left to view.
    @MainActor
    func testBrowsesSeededPhotosAndDeletesOne() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=2",
            ]
        )

        openHikeDetail(in: app)

        let strip = element("hike-photo-strip", in: app)
        XCTAssertTrue(
            scrollIntoView(strip, in: app),
            "a hike with photos should show the strip they live on"
        )
        // The tiles are identified by photo UUID, which a test cannot know;
        // their labels are their place in the walk, which it can.
        photoTile(at: 1, of: 2, in: app).tap()

        let viewer = element("photo-viewer", in: app)
        XCTAssertTrue(
            viewer.waitForExistence(timeout: UITestTimeout.navigation),
            "tapping a tile should open the photo"
        )
        XCTAssertTrue(app.buttons["Next photo"].isEnabled)

        element("photo-delete-button", in: app).tap()
        XCTAssertTrue(
            app.navigationBars["1 of 1"]
                .waitForExistence(timeout: UITestTimeout.navigation),
            "deleting one of two should leave the viewer on the other"
        )

        element("photo-delete-button", in: app).tap()
        let closed = NSPredicate(format: "exists == false")
        expectation(for: closed, evaluatedWith: viewer)
        waitForExpectations(timeout: UITestTimeout.existence)
        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle]
                .waitForExistence(timeout: UITestTimeout.navigation),
            "a viewer with nothing left to view should return to the hike"
        )
    }

    /// Sending a photo's location to the map, from the viewer's toolbar.
    ///
    /// Separated from the delete test because it ends somewhere else: the
    /// screens are dismissed back to the map, which is the assertion.
    @MainActor
    func testShowsAPhotoOnTheMap() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=2",
            ]
        )

        openHikeDetail(in: app)
        XCTAssertTrue(
            scrollIntoView(element("hike-photo-strip", in: app), in: app)
        )
        photoTile(at: 1, of: 2, in: app).tap()

        let viewer = element("photo-viewer", in: app)
        XCTAssertTrue(
            viewer.waitForExistence(timeout: UITestTimeout.navigation)
        )
        let showOnMap = element("photo-show-on-map-button", in: app)
        XCTAssertTrue(
            showOnMap.exists,
            "a seeded photo is anchored to the route, so it has a place to show"
        )
        showOnMap.tap()

        let closed = NSPredicate(format: "exists == false")
        expectation(for: closed, evaluatedWith: viewer)
        waitForExpectations(timeout: UITestTimeout.existence)
        XCTAssertTrue(
            element("trail-map", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "showing a photo on the map should take the user back to the map"
        )
    }

    /// A photo tile, found by the position it reports rather than by the
    /// identifier it carries — that identifier is the photo's UUID, which is
    /// generated at import and cannot be known from out of process.
    @MainActor
    private func photoTile(
        at index: Int,
        of count: Int,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "Photo \(index) of \(count)"
                )
            )
            .firstMatch
    }

    /// A SwiftUI `Toggle` reports its state as the string "0" or "1".
}
