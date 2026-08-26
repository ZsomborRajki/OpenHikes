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

    /// The pill belongs to the pushed screen, and has to leave with it.
    ///
    /// A pushed screen's `onDisappear` arrives only once SwiftUI has finished
    /// the pop, so the claim on its own left the pill over the map — opaque and
    /// tappable — for the whole of a back navigation, and a picker opened from
    /// it had nothing left to file into by the time a photo was chosen. The
    /// sheet reports the state of its path instead, which is also why the
    /// second half of this test matters: a rule that withdrew the pill on a pop
    /// *event* would never give it back.
    @MainActor
    func testWithdrawsTheCameraPillWhenLeavingAHike() {
        let app = launchApp(
            arguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )

        openHikeDetail(in: app)
        let camera = element("map-camera-button", in: app)
        XCTAssertTrue(
            camera.waitForExistence(timeout: UITestTimeout.navigation),
            "opening a hike should offer the pill"
        )

        popScreen(in: app)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: camera)
        waitForExpectations(timeout: UITestTimeout.existence)
        XCTAssertFalse(
            element("map-photo-library-button", in: app).exists,
            "the library button goes with the camera one"
        )

        openHikeDetail(in: app)
        XCTAssertTrue(
            element("map-camera-button", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "and reopening the hike must offer the pill again"
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

        // The camera moved to the photo's coordinate, so the sheet has to get
        // out of the way of it. Returning to the expanded height the viewer
        // was opened from would put the sheet over the very place the map was
        // just told to show.
        XCTAssertTrue(
            waitForCollapsedSheet(in: app),
            "showing a photo on the map should drop the sheet to its lowest detent"
        )
        XCTAssertTrue(
            element("photo-pin", in: app).exists,
            "an anchored photo should stand on the map where it was taken"
        )
    }

    /// The way back in: a pin on the map opens the gallery the user came from.
    ///
    /// Seeded with one photo rather than two so the assertion can name a
    /// page — with a single pin there is no question which photo a tap meant.
    /// Which photo a *shared* point speaks for is decided in `PhotoMapPin`
    /// and asserted there, where it can be checked without a simulator.
    @MainActor
    func testOpensTheGalleryFromAPhotoPinOnTheMap() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=1",
            ]
        )

        openHikeDetail(in: app)
        XCTAssertTrue(
            scrollIntoView(element("hike-photo-strip", in: app), in: app)
        )
        photoTile(at: 1, of: 1, in: app).tap()

        let viewer = element("photo-viewer", in: app)
        XCTAssertTrue(
            viewer.waitForExistence(timeout: UITestTimeout.navigation)
        )
        element("photo-show-on-map-button", in: app).tap()
        XCTAssertTrue(waitForCollapsedSheet(in: app))

        let pin = element("photo-pin", in: app)
        XCTAssertTrue(
            pin.waitForExistence(timeout: UITestTimeout.navigation),
            "the photo the map was sent to should be standing on it"
        )
        pin.tap()

        // MapKit's own callout, with the photo in its detail accessory.
        let preview = element("photo-pin-preview", in: app)
        XCTAssertTrue(
            preview.waitForExistence(timeout: UITestTimeout.existence),
            "selecting a photo pin should open a callout previewing the photo"
        )
        preview.tap()

        XCTAssertTrue(
            viewer.waitForExistence(timeout: UITestTimeout.navigation),
            "tapping a pin's preview should reopen the gallery viewer"
        )
        XCTAssertTrue(
            app.navigationBars["1 of 1"].exists,
            "the viewer should be paged to the photo whose pin was tapped"
        )
    }

    /// The whole of the library-discovery flow, from the placeholder on a hike
    /// with no photos to tiles in the strip.
    ///
    /// Only the library is faked. The window the stub answers is the one the
    /// real timeline asked for, the matching is the shipping matcher against
    /// the fixture GPX's own timestamps, and the import is the shipping
    /// importer writing real files — so watching the strip appear afterwards
    /// is watching the actual pipeline run end to end.
    ///
    /// Reopening the sheet at the end is the half that regressed most easily
    /// in development: a photo already imported must not be offered a second
    /// time, or every visit to the sheet duplicates the walk's gallery.
    @MainActor
    func testMatchesLibraryPhotosToAHikeAndImportsThem() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-photo-library=3",
            ]
        )

        openHikeDetail(in: app)

        let discover = element("photo-discovery-button", in: app)
        XCTAssertTrue(
            scrollIntoView(discover, in: app),
            "a hike with a timed route should offer to look for photos of it"
        )
        discover.tap()

        let grid = element("photo-discovery-grid", in: app)
        XCTAssertTrue(
            grid.waitForExistence(timeout: UITestTimeout.existence),
            "photos taken during the walk should be offered for review"
        )
        XCTAssertTrue(
            element("discovered-photo-0", in: app).exists,
            "and each of them should be a reviewable tile"
        )

        element("photo-discovery-add-button", in: app).tap()

        let strip = element("hike-photo-strip", in: app)
        XCTAssertTrue(
            strip.waitForExistence(timeout: UITestTimeout.existence),
            "adding the matches should close the sheet and file them into the "
                + "hike's gallery"
        )
        XCTAssertTrue(
            photoTile(at: 1, of: 3, in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "and each one should be placed at its own point on the walk"
        )

        let again = element("photo-discovery-button", in: app)
        XCTAssertTrue(
            scrollIntoView(again, in: app),
            "the offer should still stand for photos taken later"
        )
        again.tap()
        XCTAssertTrue(
            element("photo-discovery-empty", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a second look should find nothing: they are already imported"
        )
        element("photo-discovery-done-button", in: app).tap()
        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle]
                .waitForExistence(timeout: UITestTimeout.navigation),
            "and dismissing it should leave the hike standing"
        )
    }

    /// The answer nobody wants but everybody gets first: a library with nothing
    /// taken during this walk in it.
    ///
    /// Worth its own scenario because it is the state a real first run lands
    /// in, and because an empty result is easy to draw as a blank sheet — which
    /// reads as a hang rather than as an answer.
    @MainActor
    func testExplainsWhenNoLibraryPhotosMatchTheHike() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-photo-library=0",
            ]
        )

        openHikeDetail(in: app)

        let discover = element("photo-discovery-button", in: app)
        XCTAssertTrue(
            scrollIntoView(discover, in: app),
            "the offer stands whether or not the library has anything in it"
        )
        discover.tap()

        XCTAssertTrue(
            element("photo-discovery-empty", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "an empty library should be explained rather than left blank"
        )
        XCTAssertFalse(
            element("photo-discovery-add-button", in: app).exists,
            "and nothing should be offered to add"
        )
    }

    /// Waits for the sheet to be sitting at its lowest detent.
    ///
    /// Measured rather than named, because a detent is not something XCUITest
    /// can read: the compact height is a small fraction of the screen, so a
    /// sheet whose top edge is down in the bottom fifth is at it and a sheet
    /// at any other detent is not.
    @MainActor
    private func waitForCollapsedSheet(in app: XCUIApplication) -> Bool {
        let sheet = element("map-sheet", in: app)
        guard sheet.waitForExistence(timeout: UITestTimeout.navigation) else {
            return false
        }
        let collapsed = NSPredicate { _, _ in
            sheet.frame.minY > app.frame.height * Self.collapsedSheetFraction
        }
        let settled = expectation(for: collapsed, evaluatedWith: sheet)
        return XCTWaiter.wait(
            for: [settled],
            timeout: UITestTimeout.navigation
        ) == .completed
    }

    /// How far down the screen the collapsed sheet's top edge has to be.
    ///
    /// The compact detent is 80 points tall against a screen of over 800, so
    /// anything below four fifths is unambiguously it while leaving room for
    /// the home indicator and for a taller device.
    private static let collapsedSheetFraction: CGFloat = 0.8

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
}
