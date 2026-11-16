//
//  OrientationUITests+PhotoDiscovery.swift
//  OpenHikesUITests
//
//  *Find Photos of This Hike* through a turn of the phone: the sheet stays up,
//  and the photographs the hiker took out of it stay out, both ways round.
//
//  An `extension` for the reason `OrientationUITests+Gallery` is one.
//

import XCTest

extension OrientationUITests {
    /// What the bar under the grid says once one of the three stubbed
    /// photographs has been taken out.
    private static let reviewedSelection = "2 of 3 selected"

    /// Turning the phone with the sheet up leaves it up, on the choice the
    /// hiker had made; closing it and asking again still starts over.
    ///
    /// The hike's screen is drawn in the sheet in portrait and in the side
    /// panel in landscape, so a turn builds it again. While the sheet and its
    /// search were the photo section's own state, they went with it: the
    /// sheet closed, and the hiker had to search and choose again (#1462).
    @MainActor
    func testPhotoDiscoveryKeepsItsSelectionThroughRotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-photo-library=3",
        ])
        openHikeDetail(in: app)
        scrollToTap(element("photo-discovery-button", in: app), in: app)
        let grid = element("photo-discovery-grid", in: app)
        XCTAssertTrue(grid.waitForExistence(timeout: UITestTimeout.navigation), "precondition: the search finds them")
        tapWhenReady(element("discovered-photo-0", in: app))
        let selection = element("photo-discovery-selection-count", in: app)
        XCTAssertEqual(selection.label, Self.reviewedSelection, "precondition: one photograph is taken out")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        XCTAssertTrue(grid.waitForExistence(timeout: UITestTimeout.navigation), "a turn to landscape keeps it up")
        XCTAssertEqual(selection.label, Self.reviewedSelection, "and the photograph taken out stays out")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        XCTAssertTrue(grid.waitForExistence(timeout: UITestTimeout.navigation), "and turning back does too")
        XCTAssertEqual(selection.label, Self.reviewedSelection)

        tapWhenReady(element("photo-discovery-done-button", in: app))
        XCTAssertTrue(grid.waitForNonExistence(timeout: UITestTimeout.navigation), "Done closes the sheet")
        scrollToTap(element("photo-discovery-button", in: app), in: app)
        XCTAssertTrue(grid.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertEqual(selection.label, "3 of 3 selected", "and asking again starts over")
    }
}
