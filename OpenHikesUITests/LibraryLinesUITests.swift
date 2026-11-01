//
//  LibraryLinesUITests.swift
//  OpenHikesUITests
//
//  Three of the hiker's own trails side by side on the map, opened one after
//  another.
//
//  Every hike in the library is drawn on the map, faded, and the selected one
//  is taken out of them and drawn properly instead (`LibraryLines`). None of
//  that is in the accessibility tree, because MapKit draws a line as pixels,
//  so what this asserts is only what a hiker reaches through the list: each
//  trail opens, and the list comes back. The lines themselves are the unit
//  suites' (`LibraryLinesTests`, `MapCoordinatorTests+LibraryLines`).
//
//  It is here as much for `Scripts/render-trace.sh` as for the check. The
//  lines are read and drawn while the app comes up, and every selection takes
//  one line out of the library and gives the last one back, so a change that
//  lets a line landing or a selection re-run SwiftUI shows up in this test's
//  steps: `render-trace.sh --suite LibraryLinesUITests --all`.
//

import XCTest

/// The trails `--ui-test-seed-nearby-trails` adds, newest first, so in the
/// order the list draws them — see `SeededLibraryFixture.nearbyTrails`.
///
/// At file scope rather than on the class, for the reason
/// `HikeOrderUITests`' seeded count is.
private let nearbyTrailTitles = ["Malerwinkel Loop", "Rinnkendlsteig", "Gotzenalm"]

/// Between the three trailheads, so the map starts looking at all of them.
private let nearbyTrailsMapStart = "47.592,12.992"

nonisolated final class LibraryLinesUITests: XCTestCase {
    @MainActor
    func testNearbyTrailsOpenOneAfterAnother() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-seed-nearby-trails",
            "--ui-test-map-start=\(nearbyTrailsMapStart)",
        ])
        for title in nearbyTrailTitles {
            awaitHikeRow(titled: title, in: app)
        }

        for title in nearbyTrailTitles {
            openHikeDetail(in: app, titled: title)
            popScreen(in: app)
            awaitHikeRow(titled: title, in: app)
        }
    }
}
