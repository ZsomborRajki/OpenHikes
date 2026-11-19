//
//  ScreenshotUITests+MapModes.swift
//  OpenHikesUITests
//
//  App Store frame 07, *Map Modes* open over the walk, in a file of its own
//  for the reason frames 08 to 10 have one: `ScreenshotUITests.swift` is at
//  the length the linter allows.
//

import XCTest

/// Where the walk's two ends are drawn down the window.
private struct WalkSpan {
    let north: CGFloat
    let south: CGFloat

    var height: CGFloat { south - north }
    var middle: CGFloat { (north + south) / 2 }
}

extension ScreenshotUITests {
    /// The walk's northern and southern ends, from the fixture's own points:
    /// the landing in Schönau and St. Bartholomä.
    private static let walkNorth = 47.599436
    private static let walkSouth = 47.54402
    /// From the top of *Map Modes*' ✕ up to the sheet's own top edge, in
    /// points: the sheet's top padding, and a little for its glass rim.
    private static let mapModesEdgeAboveClose: CGFloat = 20
    /// Room kept between the walk and what stands over the map, in points.
    private static let walkClearance: CGFloat = 16
    /// How far down the window the status bar reaches, as a share of it.
    private static let statusBarShare: CGFloat = 0.07
    /// Where across the window the walk is zoomed from and panned by: on the
    /// lake east of it, because a tap on the drawn line opens its hike.
    private static let lakeX: CGFloat = 0.6
    /// A first guess at how many zoom levels a point of a one-finger zoom
    /// moves the map, a level for every 150 points or so, measured again
    /// after every pass.
    private static let zoomLevelsPerPoint: CGFloat = 0.007
    /// The longest one-finger zoom drawn in one pass, in points.
    private static let longestZoomDraw: CGFloat = 150
    private static let walkFittingPasses = 4
    /// Close enough to the height wanted, as a share of it.
    private static let walkFitTolerance: CGFloat = 0.06
    /// Close enough to the band's middle to leave alone, in points.
    private static let walkCenteringTolerance: CGFloat = 8
    /// The least of the window a band has to be, as a share of its height,
    /// for the walk to be drawn into it. The closed iPhone Duo's *Map Modes*
    /// stands nearly as tall as its cover display, and leaves none.
    private static let leastBandShare: CGFloat = 0.2

    /// Frames the walk, lowers the map sheet out of the way, and opens *Map
    /// Modes* over the map once its tiles have settled, then waits for the
    /// cards to draw.
    ///
    /// *Zoom* fits the walk above the sheet's middle detent, which leaves it
    /// in the top of the screen: the band *Map Modes*, as tall as its cards,
    /// leaves open — or did, until the sheet grew a row for *Offline Maps*
    /// and came up over the stretch to St. Bartholomä. So where *Map Modes*
    /// covers the walk, ``fitWalk(between:and:in:)`` draws it into the band
    /// left, and the sheet is opened again.
    ///
    /// The map sheet goes to its compact detent first, because the *Map
    /// Modes* button rides it no higher than the middle and a sheet standing
    /// there would show between the two. Beside the side panel there is no
    /// sheet to lower.
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
        // Read while the map is in reach: under *Map Modes* it is not.
        let south = walkSpan(in: app)?.south
        openMapModes(in: app)
        if let band = openBandAboveMapModes(in: app), let south, south > band.bottom {
            closeMapModes(in: app)
            fitWalk(between: band.top, and: band.bottom, in: app)
            settleScreenshotMapTiles(in: app)
            openMapModes(in: app)
        }
        XCTAssertTrue(
            element("provider-row-osm", in: app).isSelected,
            "the map behind the sheet, OpenHikes, should be the selected card"
        )
        settleScreenshotScreen(in: app)
    }

    /// The open map *Map Modes* leaves above itself, down the window: from
    /// under the status bar to above the sheet, with room to spare at both.
    /// `nil` beside the side panel, where *Map Modes* is a card in the
    /// middle and the walk stands beside it, and where the band is too
    /// short for a walk to be drawn into it.
    @MainActor
    private func openBandAboveMapModes(in app: XCUIApplication) -> (top: CGFloat, bottom: CGFloat)? {
        guard !element("map-side-panel", in: app).exists else { return nil }
        let close = element("map-modes-close", in: app)
        guard close.waitForExistence(timeout: UITestTimeout.navigation) else { return nil }
        let window = windowFrame(of: app)
        let top = window.minY + window.height * Self.statusBarShare + Self.walkClearance
        let bottom = close.frame.minY - Self.mapModesEdgeAboveClose - Self.walkClearance
        guard bottom - top >= window.height * Self.leastBandShare else { return nil }
        return (top: top, bottom: bottom)
    }

    /// Zooms the map out until the walk is as tall as the band from `top`
    /// to `bottom`, then pans it into the band's middle.
    ///
    /// With MapKit's one-finger zoom, which zooms by as much as it is drawn
    /// rather than by a whole level as a two-finger tap does, and never
    /// turns the map as a pinch does (see ``zoomMapInOneStep(in:)``). How
    /// far a point of it zooms is not known ahead, so each pass measures
    /// what the last one did, as the tilted frame measures its tilt.
    @MainActor
    private func fitWalk(between top: CGFloat, and bottom: CGFloat, in app: XCUIApplication) {
        let display = screenshotDisplay(in: app)
        let window = windowFrame(of: app)
        let wanted = bottom - top
        var rate = Self.zoomLevelsPerPoint
        var span = walkSpan(in: app)
        for _ in 0..<Self.walkFittingPasses {
            guard let walk = span else { break }
            if walk.height <= wanted, walk.height >= wanted * (1 - Self.walkFitTolerance) { break }
            let levels = log2(walk.height / (wanted * (1 - Self.walkFitTolerance / 2)))
            let distance = min(max(levels / rate, -Self.longestZoomDraw), Self.longestZoomDraw)
            let pivot = CGPoint(x: window.minX + window.width * Self.lakeX, y: walk.middle)
            XCTAssertTrue(ScreenshotDisplayGesture.zoomWithOneFinger(at: pivot, drawing: -distance, on: display))
            span = walkSpan(in: app)
            guard let zoomed = span?.height, zoomed > 0 else { break }
            let moved = log2(walk.height / zoomed)
            if abs(moved) > Self.walkFitTolerance / 2 { rate = moved / distance }
        }
        guard let walk = span else { return }
        let offset = (top + bottom) / 2 - walk.middle
        if abs(offset) > Self.walkCenteringTolerance {
            let x = window.minX + window.width * Self.lakeX
            let from = CGPoint(x: x, y: walk.middle)
            panMap(mapElement(in: app), from: from, to: CGPoint(x: x, y: from.y + offset))
        }
        if walk.height > wanted {
            attachScreenshotEvidence(named: "Walk taller than the band Map Modes leaves", in: app)
        }
    }

    /// Where the walk's ends are drawn down the window, from one reading of
    /// the camera.
    @MainActor
    private func walkSpan(in app: XCUIApplication) -> WalkSpan? {
        let ends = screenY(ofLatitudes: [Self.walkNorth, Self.walkSouth], in: app)
        guard let north = ends.first, let south = ends.last, ends.count == 2 else { return nil }
        return WalkSpan(north: north, south: south)
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
