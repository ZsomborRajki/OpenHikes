//
//  ScreenshotUITests+Landscape.swift
//  OpenHikesUITests
//
//  Compose the same captures in the Duo's side panel. Read the scrolling
//  viewport and the share boxes rather than accepting a hit-test result from
//  the folded-away cover display.
//

import XCTest

extension ScreenshotUITests {
    private static let landscapeContentMargin: CGFloat = 12

    @MainActor
    func positionScreenshotGallery(in app: XCUIApplication) {
        let strip = element("hike-photo-strip", in: app)
        guard element("map-side-panel", in: app).exists else {
            XCTAssertTrue(scrollIntoView(strip, in: app))
            return
        }
        let container = scrollContainer(in: app)
        for _ in 0..<12 {
            let viewport = container.frame.insetBy(dx: 0, dy: Self.landscapeContentMargin)
            let delta = viewport.maxY - Self.landscapeContentMargin - strip.frame.maxY
            if abs(delta) < Self.landscapeContentMargin,
               strip.frame.minY >= viewport.minY, strip.frame.maxY <= viewport.maxY { return }
            let reach = viewport.height / 2
            let distance = min(max(delta, -reach), reach)
            let start = CGPoint(x: container.frame.minX + 8, y: container.frame.midY)
            XCTAssertTrue(ScreenshotDisplayGesture.drag(
                from: start, to: CGPoint(x: start.x, y: start.y + distance), on: Self.screen(showing: app)
            ))
        }
        XCTFail("the photo gallery should be fully visible inside the side panel")
    }

    @MainActor
    func arrangeLandscapeShareCard(in app: XCUIApplication) {
        let window = windowFrame(of: app)
        guard window.width > window.height else { return }
        let stats = walkShareBox(.stats, in: app)
        let route = walkShareBox(.route, in: app)
        let before = stats.frame
        let margin = Self.landscapeContentMargin
        let title = app.staticTexts["Share Hike"]
        let titleBottom = title.exists ? title.frame.maxY : window.minY
        let target = CGPoint(
            x: window.minX + margin + before.width / 2,
            y: max(before.midY + margin, titleBottom + margin + before.height / 2)
        )
        XCTAssertTrue(ScreenshotDisplayGesture.drag(
            from: CGPoint(x: before.midX, y: before.midY), to: target, on: Self.screen(showing: app)
        ))
        let controls = element("walk-share-controls", in: app)
        XCTAssertTrue(controls.waitForExistence(timeout: UITestTimeout.navigation))
        stats.tap()
        XCTAssertTrue(controls.waitForNonExistence(timeout: UITestTimeout.navigation))
        // The route's square accessibility frame includes empty space beside
        // its narrow line. Keep the figures left of that line's center.
        XCTAssertLessThan(stats.frame.maxX, route.frame.midX, "the figures should sit beside the route")
    }

    /// An explicit display ID avoids XCTest's two-finger calculation
    /// against the inactive cover display.
    @MainActor
    func zoomRecordingMapOut(in app: XCUIApplication) {
        let map = mapElement(in: app)
        guard hitTestIsUnreliable(in: app, window: windowFrame(of: app)) else {
            map.twoFingerTap()
            return
        }
        let area = openMapArea(in: app)
        XCTAssertTrue(ScreenshotDisplayGesture.tapWithTwoFingers(
            at: CGPoint(x: area.midX, y: area.midY), on: Self.screen(showing: app)
        ))
    }

    /// Use the app's free system map for the Duo's nearby frame. The raster
    /// map can leave its new top row blank after the landscape camera move.
    @MainActor
    func prepareNearbyLandscapeMap(in app: XCUIApplication) {
        guard hitTestIsUnreliable(in: app, window: windowFrame(of: app)) else { return }
        element("settings-button", in: app).tap()
        let provider = element("provider-row-apple_maps", in: app)
        XCTAssertTrue(provider.waitForExistence(timeout: UITestTimeout.navigation))
        provider.tap()
        app.buttons["settings-close"].tap()
    }

    /// Observe rendered tiles rather than capture a placeholder grid.
    @MainActor
    func settleNearbyMapTiles(in app: XCUIApplication) {
        let ready = waitUntil(timeout: UITestTimeout.trace) {
            screenshotMapHasTiles(in: app, requireTerrain: false)
        }
        if !ready {
            let evidence = XCTAttachment(screenshot: Self.screen(showing: app).screenshot())
            evidence.name = "Nearby map still loading"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(ready, "nearby map tiles should replace the placeholder grid after framing")
    }
}
