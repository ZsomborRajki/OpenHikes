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

    /// The most a drag over the list is lengthened by for what the last one
    /// fell short by, in points: about what a scroll view spends telling a
    /// drag from a tap.
    private static let longestListSlop: CGFloat = 20
    /// How long the drag is pressed before it moves, and held before it lets
    /// go, so the list neither takes it for a tap nor coasts on.
    private static let listDragHold: TimeInterval = 0.1
    /// How far below the list's top edge a line drawn whole is left, in
    /// points.
    private static let uncutInset: CGFloat = 4
    /// Drags that may be spent drawing every line whole.
    private static let uncuttingAttempts = 5
    /// How far inside a line's frame its drawing starts and ends, in points.
    /// The lines' frames touch, each holding its own padding, so an edge
    /// within this of a frame's end cuts nothing that is drawn.
    private static let linePadding: CGFloat = 4
    /// The lines over the list's first row, in order: the sentence over
    /// *Extra Detail*, the switch, the sentence under it and *Nearby*.
    private static let headTexts = [
        "Downloads are for the OpenHikes map only.",
        "Adds buildings and small places such as water taps, toilets and benches. "
            + "Downloads take about twice the space.",
        "Nearby",
    ]

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
        uncutListTop(in: app, dragging: germany)
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

    /// Draws the list down until no line stands cut in half by its top edge.
    ///
    /// The list goes to the row chosen on the map by putting it in its
    /// middle, which at the sheet's middle stops wherever that falls: across
    /// the sentence over *Extra Detail* on the 6.9" iPhone. So the frame
    /// draws the list down until the line the edge cuts stands whole under
    /// it.
    ///
    /// A line is cut only where the edge falls inside its padding
    /// (``linePadding``): the lines' frames touch, so a line drawn whole
    /// leaves the frame over it reaching a few points past the edge, and
    /// counting that as cut drew a short list back to its head a line at a
    /// time, and Germany's row off the bottom. The drag is slow,
    /// starts on the chosen row, and is measured and drawn again rather than
    /// overshot: the list spends six to ten points of a drag telling it from
    /// a tap, so each is lengthened by what the last fell short of. Only ever
    /// down: drawn up at the sheet's middle, a list raises the sheet.
    @MainActor
    private func uncutListTop(in app: XCUIApplication, dragging handle: XCUIElement) {
        // The list's own top edge, which it is drawn under: the search field
        // and the order capsule stand over it, and the capsule's frame is a
        // finger's height rather than the capsule's.
        let list = app.collectionViews.containing(.any, identifier: "offline-country-DE").firstMatch
        var slop: CGFloat = 0
        for _ in 0..<Self.uncuttingAttempts {
            let edge = list.frame.minY
            guard let cut = lineCut(at: edge, in: app) else { return }
            let inset = cut.above.map { min(Self.uncutInset, (cut.line.minY - $0.maxY) / 2) } ?? Self.uncutInset
            let shortfall = edge + inset - cut.line.minY
            let before = handle.frame.minY
            let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grip.press(
                forDuration: Self.listDragHold,
                thenDragTo: grip.withOffset(CGVector(dx: 0, dy: shortfall + slop)),
                withVelocity: .slow,
                thenHoldForDuration: Self.listDragHold
            )
            _ = waitUntilStill(handle)
            slop = min(max(slop + shortfall - (handle.frame.minY - before), 0), Self.longestListSlop)
        }
        XCTAssertNil(
            lineCut(at: list.frame.minY, in: app),
            "no line of the list should stand half under the search field"
        )
    }

    /// The frame of the first line over the list's first row that the edge
    /// at `edge` cuts through, with the frame of the line over it where the
    /// list still holds one, or `nil` where it cuts none.
    @MainActor
    private func lineCut(at edge: CGFloat, in app: XCUIApplication) -> (line: CGRect, above: CGRect?)? {
        let texts = Self.headTexts.map { app.staticTexts[screenshotText($0)] }
        let toggle = app.switches.matching(identifier: "offline-maps-extra-detail").firstMatch
        let lines = ([texts[0], toggle] + texts.dropFirst()).map { $0.exists ? $0.frame : nil }
        guard let index = lines.firstIndex(where: { line in
            line.map { $0.minY + Self.linePadding < edge && $0.maxY - Self.linePadding > edge } ?? false
        }), let line = lines[index] else { return nil }
        return (line: line, above: index > 0 ? lines[index - 1] : nil)
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
