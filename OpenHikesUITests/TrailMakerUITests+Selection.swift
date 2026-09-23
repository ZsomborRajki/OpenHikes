//
//  TrailMakerUITests+Selection.swift
//  OpenHikesUITests
//
//  Opening the maker lets go of the selected hike, so its line is not drawn
//  across the canvas the new trail is drawn on.
//

import XCTest

extension TrailMakerUITests {
    /// The row's selection trait stands in for the line on the map: the map
    /// draws exactly the selected hike and nothing else, and a polyline has no
    /// accessibility element to ask about.
    @MainActor
    func testOpeningTheMakerDeselectsTheHike() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        let row = awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        XCTAssertTrue(waitUntilSelected(row), "an imported hike arrives selected")

        openTrailMaker(in: app)
        popScreen(in: app)

        XCTAssertTrue(
            waitUntil { row.exists && !row.isSelected },
            "opening the maker should let go of the selected hike"
        )
    }
}
