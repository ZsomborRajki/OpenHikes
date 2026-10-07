//
//  OrientationUITests+WalkShare.swift
//  OpenHikesUITests
//
//  A walk's share card through a turn of the phone: the photograph chosen and
//  where it was put are still there after it, both ways round.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    /// Turning the phone with the share card open leaves it open, on the
    /// photograph that was chosen.
    ///
    /// The summary is drawn in the sheet in portrait and in the side panel in
    /// landscape, so a turn replaces the view that presented the card. While
    /// the card was that view's own state it closed with it, and the hiker
    /// landed back on the summary without the photograph they had picked —
    /// see #795.
    @MainActor
    func testWalkShareCardSurvivesRotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-walks=HalfLoop",
            "--ui-test-seed-photos=2",
        ])
        openHikeDetail(in: app)
        app.segmentedControls["walk-segment"].buttons["History"].tap()
        let row = element("walk-row", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        row.tap()
        let share = app.buttons["walk-share"]
        XCTAssertTrue(share.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(share.wait(for: \.isEnabled, toEqual: true, timeout: UITestTimeout.existence))
        share.tap()
        let photo = app.buttons["walk-share-photo-0"]
        XCTAssertTrue(photo.waitForExistence(timeout: UITestTimeout.navigation))
        photo.tap()
        let send = app.buttons["walk-share-send"]
        XCTAssertTrue(send.waitForExistence(timeout: UITestTimeout.navigation), "precondition: the editor is open")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        XCTAssertTrue(
            send.waitForExistence(timeout: UITestTimeout.navigation),
            "turning to landscape keeps the card open on its photograph"
        )

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        XCTAssertTrue(
            send.waitForExistence(timeout: UITestTimeout.navigation),
            "and turning back does too"
        )
    }
}
