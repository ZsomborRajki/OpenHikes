//
//  ScreenshotUITests+OfflineMaps.swift
//  OpenHikesUITests
//
//  App Store frame 09, *Offline Maps* with Germany chosen on the map, in a
//  file of its own for the reason frames 08 and 10 have one:
//  `ScreenshotUITests.swift` is at the length the linter allows, and an
//  extension keeps it inside the one suite `Scripts/screenshots.sh` runs.
//

import XCTest

extension ScreenshotUITests {
    /// The list of every area the tile server offers: the `showcase`
    /// stand-in, a copy of the server's own manifest. See
    /// `SeededOfflineCountryServer.swift`.
    private static let offlineCountriesArgument = "--ui-test-offline-countries=showcase"

    /// Where on the open map the tap that chooses a country lands, as shares
    /// of its width and height: left of its middle and above it, clear of the
    /// location dot at the middle and of the map's controls down the trailing
    /// edge.
    private static let countryTapX: CGFloat = 0.35
    private static let countryTapY: CGFloat = 0.35

    /// How far a finger travels over the list before it scrolls, in points:
    /// the drag that brings the list's head back starts this far behind its
    /// mark, as ``panMap(_:from:to:)`` does over the map.
    private static let listSlop: CGFloat = 10
    /// How long the drag is pressed before it moves, and held before it lets
    /// go, so the list neither takes it for a tap nor coasts on.
    private static let listDragHold: TimeInterval = 0.1
    /// Near enough to where the head stood, in points.
    private static let headTolerance: CGFloat = 2
    /// Drags that may be spent bringing the head back.
    private static let headReturnAttempts = 3

    /// The countries a hiker can keep for a walk with no signal, over the map
    /// they cover: *Offline Maps* at the sheet's middle, Germany chosen on
    /// the map, and its row at the head of the list nearest the hiker.
    ///
    /// Reached the way a hiker reaches it: *Map Modes* from the pill, then
    /// *Offline Maps* at its foot. The hiker stands in Schönau, as in the
    /// nearby frame, so the list opens nearest first with Germany at its
    /// head, and the map behind it is a couple of kilometres of Bavaria.
    /// A tap there chooses Germany, as a tap inside any outline chooses its
    /// country; a tap on the row it chose then draws the map out to the whole
    /// country, outlined bolder and tinted among its neighbours' outlines.
    ///
    /// Nothing downloads: the launch has no download session, so the row
    /// offers *Download* with what the country costs, as a real list does
    /// before the hiker taps it.
    @MainActor
    func testCapturesDownloadingACountry() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            Self.offlineCountriesArgument,
        ])
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.schoenau)
        defer { XCUIDevice.shared.location = nil }
        launch(app)
        XCTAssertTrue(
            screenshotUserLocation(in: app).waitForExistence(timeout: UITestTimeout.trace),
            "the map should show where the hiker is before Offline Maps opens over it"
        )
        openOfflineMapsNearestFirst(in: app)

        let germany = element("offline-country-DE", in: app)
        let head = app.switches.matching(identifier: "offline-maps-extra-detail").firstMatch
        let headTop = head.frame.minY
        chooseCountryOnTheMap(in: app)
        XCTAssertTrue(waitUntilSelected(germany), "a tap on the map in Bavaria should choose Germany's row")
        // The list goes to the row it chose, which may still be moving.
        XCTAssertTrue(waitUntilStill(germany), "the list should come to rest on Germany's row")
        let before = mapElement(in: app).value as? String
        germany.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) { self.mapElement(in: app).value as? String != before },
            "a tap on Germany's row should draw the map out to the whole country"
        )
        XCTAssertTrue(germany.isSelected, "Germany should still be the chosen country")
        returnList(to: headTop, of: head, dragging: germany)
        capture(as: .offlineMaps, of: app)
    }

    /// Opens *Offline Maps*, and again until the list has the hiker's
    /// position: it reads that once as it comes up, and the app's own first
    /// fix can land after MapKit has drawn the dot.
    @MainActor
    private func openOfflineMapsNearestFirst(in app: XCUIApplication) {
        let order = element("offline-maps-order-button", in: app)
        let nearest = screenshotText("Nearest")
        let opened = waitUntil(timeout: UITestTimeout.trace) {
            openMapModes(in: app)
            scrollToTap(element("map-modes-offline-maps", in: app), in: app)
            let isNearest = waitUntil(timeout: UITestTimeout.navigation) {
                (order.value as? String) == nearest
            }
            if isNearest { return true }
            popScreen(in: app)
            return false
        }
        XCTAssertTrue(opened, "with the hiker in Schönau, Offline Maps should open nearest first")
        XCTAssertTrue(
            element("offline-country-DE", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the showcase list should hold Germany"
        )
    }

    /// Waits until `target` stands in the same place on two polls running.
    @MainActor
    private func waitUntilStill(_ target: XCUIElement) -> Bool {
        var last: CGRect?
        return waitUntil(timeout: UITestTimeout.navigation) {
            let frame = target.frame
            defer { last = frame }
            return frame == last
        }
    }

    /// Draws the list back down until `head` stands at `top`, where it stood
    /// when the list came up.
    ///
    /// The list goes to the row chosen on the map by putting it in its
    /// middle, which near the head of a list at the sheet's middle moves it
    /// up by part of a row: far enough to cut the sentence over *Extra
    /// Detail* in half under the search field. So the frame takes it back,
    /// with a slow drag that starts on the chosen row, measured and drawn
    /// again rather than overshot — past the list's head, a drag would move
    /// the sheet.
    @MainActor
    private func returnList(to top: CGFloat, of head: XCUIElement, dragging handle: XCUIElement) {
        for _ in 0..<Self.headReturnAttempts {
            let shortfall = top - head.frame.minY
            guard shortfall > Self.headTolerance else { return }
            let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grip.withOffset(CGVector(dx: 0, dy: -Self.listSlop)).press(
                forDuration: Self.listDragHold,
                thenDragTo: grip.withOffset(CGVector(dx: 0, dy: shortfall)),
                withVelocity: .slow,
                thenHoldForDuration: Self.listDragHold
            )
            _ = waitUntilStill(head)
        }
        XCTAssertLessThanOrEqual(
            top - head.frame.minY,
            Self.headTolerance,
            "the list's head should stand whole under the search field again"
        )
    }

    /// Taps the open map at ``countryTapX`` and ``countryTapY``, inside
    /// Germany: the map is centred on Schönau, a couple of kilometres across,
    /// and the border is several kilometres off on every side.
    @MainActor
    private func chooseCountryOnTheMap(in app: XCUIApplication) {
        let open = openMapArea(in: app)
        let point = CGPoint(
            x: open.minX + open.width * Self.countryTapX,
            y: open.minY + open.height * Self.countryTapY
        )
        coordinate(at: point, on: mapElement(in: app)).tap()
    }
}
