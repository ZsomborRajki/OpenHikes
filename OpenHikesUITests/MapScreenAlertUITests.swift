//
//  MapScreenAlertUITests.swift
//  OpenHikesUITests
//
//  That an alert on the map screen can be raised at all, and that raising one
//  leaves the sheet where it was.
//
//  Both halves are the bug. `OpenHikesView` keeps `MapSheet` presented
//  permanently, and the alerts used to be attached to the view presenting it —
//  so a SwiftUI alert had nowhere to go. Raised while the sheet was settled it
//  opened and took the sheet down for the rest of the launch: no search field,
//  no hikes, and no gesture that brought either back. Raised while the sheet
//  was still going up it never appeared at all, which is why the first failure
//  went unreported for so long — a swallowed alert leaves nothing behind.
//
//  Reported by the user 2026-09-20: taking location access away in Settings,
//  coming back, and tapping the map's location button left a bare map.
//
//  Neither is a state a unit test can reach. What went wrong is which view a
//  presentation was attached to, and only a running app resolves that.
//

import XCTest

nonisolated final class MapScreenAlertUITests: XCTestCase {
    /// A launch with no location access shows the stand-in location button,
    /// which explains itself rather than spinning — and the sheet outlives
    /// the explanation.
    ///
    /// Tapped repeatedly on purpose: that is the hiker's own reproduction,
    /// and a second tap arriving while the first alert is presenting is
    /// exactly the race a single tap can miss.
    @MainActor
    func testTheLocationAlertLeavesTheSheetUp() {
        let app = launchApp()
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(
            sheet.waitForExistence(timeout: UITestTimeout.navigation),
            "the sheet should be up before anything is tapped"
        )

        let refused = element("location-access-refused", in: app)
        XCTAssertTrue(
            refused.waitForExistence(timeout: UITestTimeout.navigation),
            "a launch with no location access should show the stand-in button"
        )
        for _ in 0..<Self.rapidTaps {
            refused.tap()
            XCTAssertTrue(
                sheet.exists,
                "the sheet should still be up while the alert is being raised"
            )
        }

        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "the button should say why it can't do anything"
        )
        alert.buttons["Not Now"].tap()

        XCTAssertTrue(
            waitUntil { sheet.exists },
            "and the sheet should still be there once the alert is dismissed"
        )
    }

    /// A file that couldn't be read is reported. It used to be swallowed:
    /// the alert was raised while the sheet was going up, and never opened.
    @MainActor
    func testAnUnreadableImportIsReported() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=NoSuchFixture"])
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: UITestTimeout.navigation))

        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "a file that couldn't be read should say so rather than vanish"
        )
        alert.buttons["OK"].tap()

        XCTAssertTrue(
            waitUntil { sheet.exists },
            "and the sheet should have survived the report"
        )
    }

    /// A file with two tracks asks which to import, from inside the sheet's
    /// contents like every other modal here — a sheet attached beside the
    /// permanent one would never open, and the import would wait forever on
    /// a question nobody could see.
    @MainActor
    func testAMultiTrackImportAsksWhichTracks() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=ThumseeTwoDays"])
        let importButton = element("gpx-track-choice-import", in: app)
        XCTAssertTrue(
            importButton.waitForExistence(timeout: UITestTimeout.navigation),
            "a file with two tracks should ask which to import"
        )
        let second = element("gpx-track-1", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: UITestTimeout.existence))
        second.tap()
        importButton.tap()

        XCTAssertTrue(
            awaitHikeRow(titled: "Thumsee Day 1", in: app).exists,
            "the ticked track should become a hike"
        )
        XCTAssertFalse(hikeRow(titled: "Thumsee Day 2", in: app).exists, "and the unticked one should not")
        XCTAssertTrue(element("map-sheet", in: app).exists, "and the sheet should have survived the question")
    }

    /// Enough taps to land one inside another's presentation, and few enough
    /// that the test is over in a couple of seconds.
    private static let rapidTaps = 5
}
