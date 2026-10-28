//
//  PhotoUITests+DetailReturn.swift
//  OpenHikesUITests
//
//  A push over detail keeps its state while SwiftUI restarts its tasks on Back.
//

import XCTest

extension PhotoUITests {
    @MainActor
    func testReturningFromAPhotoKeepsHikeDetailWorking() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-photos=2",
        ])
        openHikeDetail(in: app)

        for index in 1...2 {
            let strip = element("hike-photo-strip", in: app)
            XCTAssertTrue(scrollIntoView(strip, in: app))
            photoTile(at: index, of: 2, in: app).tap()
            XCTAssertTrue(element("photo-viewer", in: app).waitForExistence(timeout: UITestTimeout.navigation))
            popScreen(in: app)
            XCTAssertTrue(
                app.navigationBars[UITestFixture.importedHikeTitle]
                    .waitForExistence(timeout: UITestTimeout.navigation)
            )
            XCTAssertTrue(strip.waitForExistence(timeout: UITestTimeout.navigation))
        }
    }
}
