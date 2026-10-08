//
//  ScreenshotUITests+Share.swift
//  OpenHikesUITests
//
//  App Store frame 10, a walk shared as a picture, in a file of its own for
//  the reason frames 08 and 09 have one: `ScreenshotUITests.swift` is at the
//  length the linter allows, and an extension keeps it inside the one suite
//  `Scripts/screenshots.sh` runs.
//

import XCTest

extension ScreenshotUITests {
    /// Which of the hike's photographs the card is put on: the sixth along
    /// the walk, the viewing platform with the Königssee below it — the walk
    /// the card is about, seen from the walk.
    private static let sharePhotoIndex = 5

    /// The walk the summary leads with, over one of its own photographs: the
    /// distance, the climb, the time and the pace in one box, the line walked
    /// in another, and OpenHikes signed along the bottom.
    ///
    /// The card editor as it opens, with no box selected, because that is the
    /// picture a hiker sends. The photographs go in through the real library
    /// and the real matcher, as frames 01 and 02's do, so the frame skips
    /// without the stamped library.
    @MainActor
    func testCapturesSharingAHike() throws {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-seed-walks=FullLoop,HalfLoop",
            Self.routeHueArgument,
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        try importDiscoveredPhotos(in: app)

        app.segmentedControls["walk-segment"].buttons["History"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "walk-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence), "the seeded walk should be listed")
        row.tap()

        let share = app.buttons["walk-share"]
        XCTAssertTrue(share.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(
            share.wait(for: \.isEnabled, toEqual: true, timeout: UITestTimeout.existence),
            "Share waits only for the trail's profile"
        )
        share.tap()

        let photo = app.buttons["walk-share-photo-\(Self.sharePhotoIndex)"]
        XCTAssertTrue(
            photo.waitForExistence(timeout: UITestTimeout.navigation),
            "the hike's photographs should be offered for the card"
        )
        photo.tap()
        XCTAssertTrue(
            walkShareBox(.stats, in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the editor should open on the photograph"
        )
        XCTAssertTrue(walkShareBox(.route, in: app).exists, "and the line walked beside the figures")
        capture(as: .share)
    }
}
