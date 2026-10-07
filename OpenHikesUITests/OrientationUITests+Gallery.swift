//
//  OrientationUITests+Gallery.swift
//  OpenHikesUITests
//
//  The hiker's own gallery in landscape: where its pages come to rest, and
//  what *Show on map* does to the panel it fills.
//
//  Split out of `OrientationUITests` for the reason `PhotoUITests+SheetHeight`
//  was — an `extension` keeps these methods members of the class, so
//  `--suite OrientationUITests` still selects them, rather than a second class
//  `single_test_class` forbids.
//

import XCTest

extension OrientationUITests {
    /// How far a settled page's middle may sit from the window's. Rounding,
    /// not drift: the drift this guards against was 31 points a page.
    private static let centringTolerance: CGFloat = 2

    /// Every page of a landscape gallery comes to rest in the middle of the
    /// window, not only the first and the last.
    ///
    /// In landscape the pager spans the window with the safe-area insets as
    /// content insets, and `.paging` stepped by a size of its own reckoning
    /// rather than the pages' width — 31 points further left on every swipe,
    /// until the clamp at the end put the last page back. So the page asserted
    /// is a middle one, two swipes in, where the drift had reached 62 points.
    @MainActor
    func testLandscapeGalleryPagesStayCentred() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-photos=4",
        ])
        openHikeDetail(in: app)
        XCTAssertTrue(scrollIntoView(element("hike-photo-strip", in: app), in: app))
        photoTile(at: 1, of: 4, in: app).tap()
        XCTAssertTrue(app.navigationBars["1 of 4"].waitForExistence(timeout: UITestTimeout.navigation))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))

        let pager = app.scrollViews["photo-viewer"]
        XCTAssertTrue(pager.waitForExistence(timeout: UITestTimeout.navigation))
        for page in 2...3 {
            pager.swipeLeft()
            XCTAssertTrue(app.navigationBars["\(page) of 4"].waitForExistence(timeout: UITestTimeout.navigation))
        }
        // The picture on screen is the one the window's middle falls in, and
        // its middle has to be the window's — to the point, give or take
        // rounding, once the swipe has settled.
        let pictures = pager.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Photo taken"))
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                pictures.allElementsBoundByIndex.contains { picture in
                    let frame = picture.frame
                    return frame.minX < app.frame.midX && frame.maxX > app.frame.midX
                        && abs(frame.midX - app.frame.midX) <= Self.centringTolerance
                }
            },
            "the third page should rest in the middle of the window"
        )
    }

    /// *Show on map* in landscape gives the map its half back with the
    /// gallery still open in the panel, and a tap on the photograph takes the
    /// window again.
    @MainActor
    func testLandscapeShowOnMapNarrowsTheGallery() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launchUpright(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-photos=2",
        ])
        openHikeDetail(in: app)
        XCTAssertTrue(scrollIntoView(element("hike-photo-strip", in: app), in: app))
        photoTile(at: 1, of: 2, in: app).tap()
        XCTAssertTrue(app.navigationBars["1 of 2"].waitForExistence(timeout: UITestTimeout.navigation))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        let panel = element("map-side-panel", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                panel.frame.width > app.frame.width * Self.minimumFilledWindowShare
            },
            "precondition: the photograph took the window"
        )

        element("photo-show-on-map-button", in: app).tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                panel.frame.width < app.frame.width * Self.maximumSheetWidthShare
            },
            "showing the photo on the map should give the map its half back"
        )
        XCTAssertTrue(
            app.navigationBars["1 of 2"].exists,
            "with the gallery still open in the panel"
        )

        // The middle of the panel is the middle of the photograph, drawn
        // scaled to fit and centred in its page.
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                panel.frame.width > app.frame.width * Self.minimumFilledWindowShare
            },
            "a tap on the photograph should take the window again"
        )
    }
}
