//
//  ScreenshotUITests+MapModes.swift
//  OpenHikesUITests
//
//  App Store frame 07, *Map Modes* open over the walk, in a file of its own
//  for the reason frames 08 to 10 have one: `ScreenshotUITests.swift` is at
//  the length the linter allows.
//

import XCTest

extension ScreenshotUITests {
    /// Frames the walk, lowers the map sheet out of the way, and opens *Map
    /// Modes* over the map once its tiles have settled, then waits for the
    /// cards to draw.
    ///
    /// *Zoom* fits the walk above the sheet's middle detent, which leaves it
    /// in the top of the screen: the band *Map Modes*, as tall as its cards,
    /// leaves open. The map sheet goes to its compact detent first, because
    /// the *Map Modes* button rides it no higher than the middle and a sheet
    /// standing there would show between the two. Beside the side panel there
    /// is no sheet to lower.
    ///
    /// The cards are drawn from tiles of their own, over the ground the map
    /// is on — with no location, as here, `TilePreviewFrame`'s fallback, which
    /// is this valley — after the sheet is up, with a spinner in each until
    /// they arrive. So the frame waits for the whole screen to stop changing
    /// rather than for the map alone.
    @MainActor
    func showRouteUnderMapModes(in app: XCUIApplication) {
        let zoom = app.buttons[screenshotText("Zoom")]
        XCTAssertTrue(
            scrollIntoView(zoom, in: app),
            "the detail screen should offer to frame the whole route"
        )
        zoom.tap()
        collapseSheet(in: app)
        settleScreenshotMapTiles(in: app)
        openMapModes(in: app)
        XCTAssertTrue(
            element("provider-row-osm", in: app).isSelected,
            "the map behind the sheet, OpenHikes, should be the selected card"
        )
        settleScreenshotScreen(in: app)
    }

    /// Waits until nothing in the capture has changed for the quiet interval
    /// the map frames wait for.
    @MainActor
    private func settleScreenshotScreen(in app: XCUIApplication) {
        let display = screenshotDisplay(in: app)
        var previous: Int?
        var stableSince = ProcessInfo.processInfo.systemUptime
        let settled = waitUntil(timeout: UITestTimeout.trace) {
            let signature = screenshotSignature(on: display)
            let now = ProcessInfo.processInfo.systemUptime
            if signature == nil || previous != signature { stableSince = now }
            previous = signature
            return signature != nil && now - stableSince >= Self.mapQuietInterval
        }
        if !settled {
            attachScreenshotEvidence(named: "Map Modes still drawing", in: app)
        }
        XCTAssertTrue(settled, "the Map Modes cards should finish drawing their previews")
    }
}
