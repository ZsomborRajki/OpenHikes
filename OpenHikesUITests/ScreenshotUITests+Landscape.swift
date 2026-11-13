//
//  ScreenshotUITests+Landscape.swift
//  OpenHikesUITests
//
//  Compose the same captures in the side panel: the open Duo's on its side,
//  and an iPad's either way up. Read the scrolling viewport and the share
//  boxes rather than accepting a hit-test result, which on the Duo comes from
//  the folded-away cover display and on an iPad is no for the whole panel.
//

import XCTest

extension ScreenshotUITests {
    private static let landscapeContentMargin: CGFloat = 12
    private static let mapQuietInterval: TimeInterval = 3

    /// Importing photos leaves the panel scrolled to Find Photos. For the
    /// map-first frames, start the card at its full title rather than leave
    /// half that title hidden behind the pinned navigation controls.
    @MainActor
    func positionLandscapeHikeHeader(in app: XCUIApplication) {
        let titles = app.staticTexts.matching(NSPredicate(format: "label == %@", Self.routeTitle))
        guard let title = titles.allElementsBoundByIndex.max(by: { $0.frame.height < $1.frame.height }) else {
            XCTFail("the hike should have its full title in the side panel")
            return
        }
        alignInScreenshotViewport(title, edge: .top, tolerance: 24, in: app, named: "Landscape title")
    }

    @MainActor
    func positionScreenshotGallery(in app: XCUIApplication) {
        if positionCompactScreenshotGallery(in: app) { return }
        let strip = element("hike-photo-strip", in: app)
        guard element("map-side-panel", in: app).exists else {
            XCTAssertTrue(scrollIntoView(strip, in: app))
            return
        }
        // An iPad's panel is tall enough to show the gallery under the chart
        // that was just tapped, with nothing scrolled: the whole frame as it
        // stands, and a strip that no drag could bring to the bottom edge.
        let viewport = scrollContainer(in: app).frame.intersection(windowFrame(of: app))
        if viewport.contains(strip.frame) { return }
        alignInScreenshotViewport(
            strip, edge: .bottom, tolerance: 24, in: app, named: "Landscape gallery", leadingDrag: true
        )
    }

    @MainActor
    func arrangeLandscapeShareCard(in app: XCUIApplication) {
        let window = windowFrame(of: app)
        guard window.width > window.height else { return }
        let stats = walkShareBox(.stats, in: app)
        let route = walkShareBox(.route, in: app)
        let before = stats.frame
        let margin = Self.landscapeContentMargin
        let title = app.staticTexts[screenshotText("Share Hike")]
        let titleBottom = title.exists ? title.frame.maxY : window.minY
        let target = CGPoint(
            x: window.minX + margin + before.width / 2,
            y: max(before.midY + margin, titleBottom + margin + before.height / 2)
        )
        XCTAssertTrue(ScreenshotDisplayGesture.drag(
            from: CGPoint(x: before.midX, y: before.midY), to: target, on: screenshotDisplay(in: app)
        ))
        let controls = element("walk-share-controls", in: app)
        XCTAssertTrue(controls.waitForExistence(timeout: UITestTimeout.navigation))
        stats.tap()
        XCTAssertTrue(controls.waitForNonExistence(timeout: UITestTimeout.navigation))
        // The route's square accessibility frame includes empty space beside
        // its narrow line. Keep the figures left of that line's center.
        XCTAssertLessThan(stats.frame.maxX, route.frame.midX, "the figures should sit beside the route")
    }

    /// Element gestures can miss either Duo display: even on its closed
    /// cover, ten zooms left the measured stroke unchanged. Target the
    /// capture's display explicitly whenever the device has two screens.
    @MainActor
    func zoomRecordingMapOut(in app: XCUIApplication) {
        let map = mapElement(in: app)
        let display = screenshotDisplay(in: app)
        guard XCUIScreen.screens.count > 1 else {
            map.twoFingerTap()
            return
        }
        let area = openMapArea(in: app)
        XCTAssertTrue(ScreenshotDisplayGesture.tapWithTwoFingers(
            at: CGPoint(x: area.midX, y: area.midY), on: display
        ))
    }

    /// Use the app's free system map for the Duo's nearby frame. The raster
    /// map can leave its new top row blank after the landscape camera move.
    ///
    /// The open Duo on its side and nothing else: an iPad's hit test is as
    /// unreliable, and its nearby frame keeps the map every other frame has.
    @MainActor
    func prepareNearbyLandscapeMap(in app: XCUIApplication) {
        guard XCUIScreen.screens.count > 1,
              hitTestIsUnreliable(in: app, window: windowFrame(of: app)) else { return }
        selectMap("apple_maps", in: app)
    }

    /// Observe rendered tiles and their final redraw, including replacement
    /// of lower-resolution fallback tiles after the camera move.
    ///
    /// `requireTerrain` also asks for most of the map to be coloured land, and
    /// `rejectSmallLoadingPatches` for next to none of it to be loading grid:
    /// what a frame can ask depends on its map's palette, which
    /// ``screenshotMapSample(in:on:requireTerrain:rejectSmallLoadingPatches:)``
    /// has the reasons for.
    @MainActor
    func settleScreenshotMapTiles(
        in app: XCUIApplication, requireTerrain: Bool = false, rejectSmallLoadingPatches: Bool = false
    ) {
        let display = screenshotDisplay(in: app)
        var previousSignature: Int?
        var stableSince = ProcessInfo.processInfo.systemUptime
        let ready = waitUntil(timeout: UITestTimeout.trace) {
            guard let sample = screenshotMapSample(
                in: app,
                on: display,
                requireTerrain: requireTerrain,
                rejectSmallLoadingPatches: rejectSmallLoadingPatches
            ), sample.hasTiles else {
                previousSignature = nil
                return false
            }
            let now = ProcessInfo.processInfo.systemUptime
            if previousSignature != sample.signature { stableSince = now }
            previousSignature = sample.signature
            return now - stableSince >= Self.mapQuietInterval
        }
        if !ready {
            attachScreenshotEvidence(named: "Map still loading", in: app)
        }
        XCTAssertTrue(ready, "map tiles should replace the placeholder grid and finish redrawing after framing")
    }
}
