//
//  ScreenshotUITests+Maps.swift
//  OpenHikesUITests
//
//  App Store frame 06, the walk on a map made for mountains, in a file of its
//  own for the reason frames 08 and 09 have one: `ScreenshotUITests.swift` is
//  at the length the linter allows, and an extension keeps it inside the one
//  suite `Scripts/screenshots.sh` runs.
//

import XCTest

extension ScreenshotUITests {
    /// The walk on Stadia Outdoors, filling the screen: hillshading and
    /// contours under the same line and the same photographs as the hero.
    ///
    /// Every other frame draws OpenStreetMap's standard map, so this is the
    /// one that shows a map can be chosen — and what OpenHikes Pro buys, which
    /// is this map and saving a whole route of it for a valley with no
    /// signal. It used to be the offline frame: the hike's screen raised over
    /// the map it was about, with an idle *Offline* button the only thing in
    /// the picture that said so. The button cannot share the picture with the
    /// map: a sheet at its middle detent grows before its contents scroll, and
    /// *Zoom* puts it back there with them scrolled to the top.
    ///
    /// Stadia Outdoors has to be selected first. `--ui-test-entitled` grants
    /// the Pro entitlement but selects nothing.
    @MainActor
    func testCapturesMapsForTheMountains() throws {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-entitled",
            "--ui-test-weather",
            Self.routeHueArgument,
        ])
        element("settings-button", in: app).tap()
        let stadia = element("provider-row-stadia_outdoors", in: app)
        XCTAssertTrue(
            stadia.waitForExistence(timeout: UITestTimeout.navigation),
            "an entitled launch should offer Stadia Outdoors — check that "
                + "OpenHikes/Secrets.plist carries a Stadia key"
        )
        stadia.tap()
        app.buttons["settings-close"].tap()

        openHikeDetail(in: app, titled: Self.routeTitle)
        try importDiscoveredPhotos(in: app, selecting: Self.pinnedPhotoIndexes)
        let zoom = app.buttons["Zoom"]
        XCTAssertTrue(scrollIntoView(zoom, in: app), "the detail screen should offer to frame the whole route")
        zoom.tap()
        collapseSheet(in: app)
        XCTAssertTrue(
            element("photo-pin", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the photographs should stand on the map where they were taken"
        )
        expandRouteIntoTheFreedSpace(in: app)
        capture(as: .maps)
    }
}
