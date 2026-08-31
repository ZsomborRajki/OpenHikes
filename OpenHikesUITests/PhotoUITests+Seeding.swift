//
//  PhotoUITests+Seeding.swift
//  OpenHikesUITests
//
//  Where the seeded gallery comes from, rather than what can be done with it.
//
//  Every other scenario in this bundle takes the seeded photos as given and
//  drives the screens they appear on. This one is about the seeding itself:
//  the fixture attaches its photos to the hike the import produced, and that
//  hike is not always the hike the map ends up showing.
//

import XCTest

extension PhotoUITests {
    /// The seeded photos belong to the hike that was imported, whether or not
    /// that hike ever became the selected one.
    ///
    /// An import takes over the map only if nothing else claimed it while the
    /// GPX was parsing, and a hike that loses that race is still persisted,
    /// still listed, and still the one the scenario asked to photograph.
    /// `--ui-test-lose-import-selection` is what stands the launch on the
    /// losing side of it; reaching that branch otherwise needs a tap to land
    /// inside the milliseconds a parse takes.
    ///
    /// Seeding used to read the selection rather than the hike the import
    /// returned, so on this launch it photographed nothing at all — and the
    /// failure it produced was an empty gallery, which looks exactly like a
    /// hike nobody photographed.
    @MainActor
    func testSeedsPhotosOntoAnImportedHikeThatLostTheSelection() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=2",
                "--ui-test-lose-import-selection",
            ]
        )

        // Losing the map is not losing the import: the row is there to open.
        openHikeDetail(in: app)

        let strip = element("hike-photo-strip", in: app)
        XCTAssertTrue(
            strip.waitForExistence(timeout: UITestTimeout.existence),
            "the photos should have been seeded onto the imported hike rather "
                + "than onto whatever the map ended up showing"
        )
        XCTAssertTrue(scrollIntoView(strip, in: app))
        XCTAssertTrue(
            photoTile(at: 2, of: 2, in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "and both of them should be on it"
        )
    }
}
