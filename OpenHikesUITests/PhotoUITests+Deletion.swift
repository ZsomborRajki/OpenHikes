//
//  PhotoUITests+Deletion.swift
//  OpenHikesUITests
//
//  The consent the gallery asks for before removing a photograph belongs to
//  the hike, whose metadata syncs, rather than to the file on this phone. The
//  distinction matters most when this phone has no file at all: its toolbar
//  still permits deleting the photograph from the hike on every device.
//

import XCTest

extension PhotoUITests {
    @MainActor
    func testExplainsPhotoDeletionAcrossDevices() {
        assertPhotoDeletionDisclosure(omitsFiles: false)
    }

    @MainActor
    func testExplainsUnavailablePhotoDeletionAcrossDevices() {
        assertPhotoDeletionDisclosure(omitsFiles: true)
    }

    @MainActor
    private func assertPhotoDeletionDisclosure(omitsFiles: Bool) {
        var arguments = [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-photos=1",
        ]
        if omitsFiles { arguments.append("--ui-test-omit-photo-files") }
        let app = launchApp(arguments: arguments)
        openHikeDetail(in: app)
        XCTAssertTrue(scrollIntoView(element("hike-photo-strip", in: app), in: app))
        photoTile(at: 1, of: 1, in: app).tap()
        XCTAssertTrue(element("photo-viewer", in: app).waitForExistence(timeout: UITestTimeout.navigation))

        if omitsFiles {
            XCTAssertTrue(
                element("photo-not-on-this-device", in: app).waitForExistence(timeout: UITestTimeout.existence),
                "the same warning is needed even when this phone has no photo file"
            )
        } else {
            XCTAssertTrue(element("photo-share-button", in: app).waitForExistence(timeout: UITestTimeout.existence))
        }

        element("photo-delete-button", in: app).tap()
        let disclosure = app.staticTexts[
            "The photo is removed from this hike on all your synced devices. "
                + "Any copy in OpenHikes on this device is deleted for good."
        ]
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: UITestTimeout.navigation),
            "deleting a photo must explain the synced hike removal and the loss of its local OpenHikes copy"
        )
        confirmDestructive("Delete Photo", in: app, failureMessage: "photo deletion should ask for consent")
        XCTAssertTrue(
            app.navigationBars[UITestFixture.importedHikeTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "removing the last photo should leave the empty viewer"
        )
    }
}
