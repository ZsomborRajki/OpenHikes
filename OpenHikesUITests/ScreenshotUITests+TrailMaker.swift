//
//  ScreenshotUITests+TrailMaker.swift
//  OpenHikesUITests
//
//  App Store frame 08, the trail maker, in a file of its own because
//  `ScreenshotUITests.swift` is at the length the linter allows. An extension
//  rather than a class, so `Scripts/screenshots.sh` still reaches it by the
//  one suite name it runs.
//

import CoreLocation
import XCTest

extension ScreenshotUITests {
    /// Drawing a trail: the one frame in the set that shows the app *making*
    /// something rather than showing something — and what it makes is the
    /// walk the hero frame is of, planned the way a hiker would plan it from
    /// home.
    ///
    /// **Walking, not Hiking.** A Hiking leg follows mapped paths by asking
    /// Overpass, and no launch under automation may reach a volunteer-run API.
    /// Walking asks Apple Maps, and `--ui-test-live-maker` lets this one launch
    /// do so — see ``AppLaunchEnvironment/asksLiveMakerServices``. It is not a
    /// lesser route here: measured against the fixture's own line, Apple's
    /// walking answer through these three stops runs a median 7 m from
    /// relation 222517, which is to say up the same path to Kühroint and down
    /// the Rinnkendlsteig. The climb in the header is Stadia's, as it is for a
    /// hiker, which is why the Pro grant is passed too.
    ///
    /// **The stops are searched for rather than pressed.** This frame used to
    /// press four points onto the map, and a press lands wherever a camera
    /// still settling puts it — measured at up to 0.28 of the screen away
    /// from the tap. A name lands on the place.
    ///
    /// The simulator is put where the walk starts, so the search is answered
    /// near Königssee rather than wherever the simulator thinks it is — and at
    /// the Schönau stop rather than the fixture's trailhead, 700 m north,
    /// where the location dot read as a second start.
    @MainActor
    func testCapturesDrawingATrail() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-live-maker",
            "--ui-test-entitled",
        ])
        // No `resetAuthorizationStatus`: the script grants location before the
        // run, so no prompt lands on this frame's first gesture. The monitor
        // stays for a run started some other way.
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.walkStart)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        XCTAssertTrue(
            element("trail-map", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the map should be up before anything is drawn on it"
        )
        openTrailMaker(in: app)
        chooseWalking(in: app)

        for (index, stop) in Self.searchedStops.enumerated() {
            element(stop.row, in: app).tap()
            pickSearchResult(stop, in: app)
            XCTAssertTrue(
                element("trail-draft-point-\(index + 1)", in: app)
                    .waitForExistence(timeout: UITestTimeout.navigation),
                "picking \(stop.title) should put point \(index + 1) down"
            )
        }
        waitForTheWalkedRoute(in: app)
        capture(as: .trailMaker)
    }

    // MARK: - Support

    /// One stop of the drawn frame: which row opens its search, what is typed,
    /// and the suggestion that is tapped.
    private struct SearchedStop {
        /// The row whose tap opens the search this stop is picked in.
        let row: String
        /// Plain ASCII. The completer matches "Kuhroint" to Kühroint, and
        /// typing an umlaut through the simulator's keyboard is one more thing
        /// that can go wrong for no gain.
        let query: String
        /// The suggestion's title, which is also what the stop is called.
        let title: String
    }

    /// Start, destination, then *Add Stop* — which appends, so the stop that
    /// ends the walk is picked last and the one in the middle is picked as the
    /// destination first.
    ///
    /// **Schönau rather than *My Location*,** although the simulated location
    /// is the fixture's first point exactly. A launch under test names no
    /// stop — see `makeTrailStopNaming()` — so a *My Location* start reads
    /// "Start" in a frame where the other two rows read as places. Schönau
    /// joins the fixture's line about 700 m in, where its opening village
    /// street meets the path.
    private static let searchedStops = [
        SearchedStop(
            row: "trail-draft-open-start",
            query: "Schonau am Konigssee",
            title: "Schönau am Königssee"
        ),
        SearchedStop(row: "trail-draft-open-destination", query: "Kuhroint", title: "Kühroint"),
        SearchedStop(row: "trail-draft-add-stop", query: "St Bartholoma", title: "St. Bartholomä"),
    ]

    /// Where Apple's search puts *Schönau am Königssee*: the village by the
    /// boat landing, where the first stop goes down.
    private static let walkStartLatitude = 47.592975
    private static let walkStartLongitude = 12.987199
    private static let walkStart = CLLocationCoordinate2D(
        latitude: walkStartLatitude,
        longitude: walkStartLongitude
    )

    /// How long the walked route has to arrive in: two Apple directions
    /// answers, the maker's two-second settle, and one Stadia call.
    private static let walkedRouteTimeout: TimeInterval = 60

    /// Selects Walking, before the first stop so no leg is ever routed as a
    /// straight Hiking line first and then re-routed.
    ///
    /// Through ``tapUntilSelected(_:timeout:)``, because this is the second
    /// segmented picker whose first tap is lost in dark appearance. It was
    /// blamed on the location alert first; the script grants location before
    /// the run now, and the dark pass still lost the tap on both attempts.
    @MainActor
    private func chooseWalking(in app: XCUIApplication) {
        let walking = app.segmentedControls["trail-draft-mode"].buttons["Walking"]
        XCTAssertTrue(walking.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(tapUntilSelected(walking), "the maker should switch to Walking")
    }

    /// Types a stop's name into the search sheet and taps the suggestion that
    /// is that place.
    ///
    /// Matched by title *and* by the address mentioning Königssee, because the
    /// completer answers "Kuhroint" with a hut of that name in Bischofswiesen
    /// too, and "St Bartholoma" with a village in Styria. The title is followed
    /// by the comma the row's combined label puts before its address, so
    /// "St. Bartholomä" does not also match *Wirtshaus St. Bartholomä*.
    @MainActor
    private func pickSearchResult(_ stop: SearchedStop, in app: XCUIApplication) {
        let field = element("trail-stop-search-field", in: app)
        XCTAssertTrue(
            field.waitForExistence(timeout: UITestTimeout.navigation),
            "\(stop.row) should open the search sheet"
        )
        field.tap()
        dismissKeyboardTip(in: app)
        field.typeText(stop.query)
        let suggestion = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH[cd] %@ AND label CONTAINS[cd] %@",
                "\(stop.title),",
                "Königssee"
            )
        ).firstMatch
        XCTAssertTrue(
            suggestion.waitForExistence(timeout: UITestTimeout.existence),
            "the search should offer \(stop.title) for \"\(stop.query)\""
        )
        suggestion.tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { !field.exists },
            "picking \(stop.title) should close the search"
        )
    }

    /// The keyboard's one-time *slide to type* card, which a simulator erased
    /// for every run shows on the first keyboard it raises — over the
    /// suggestions this frame is about to tap. A bounded wait for something
    /// that is usually absent, which is what ``UITestTimeout/brief`` is for.
    @MainActor
    private func dismissKeyboardTip(in app: XCUIApplication) {
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: UITestTimeout.brief) {
            tip.tap()
        }
    }

    /// Waits until both legs have come back from Apple and the climb has come
    /// back from Stadia for that same line.
    ///
    /// Read in one condition rather than two waits, because the two undo each
    /// other: the maker drops a measured climb the instant its line moves, so
    /// a climb for the straight line can arrive while a leg is still being
    /// routed, and then vanish. Both at once is only true of the finished line.
    @MainActor
    private func waitForTheWalkedRoute(in app: XCUIApplication) {
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Route'"))
            .firstMatch
        let legs = (2...Self.searchedStops.count).map { element("trail-draft-point-\($0)", in: app) }
        let arrived = waitUntil(timeout: Self.walkedRouteTimeout) {
            let routed = legs.allSatisfy { leg in
                let value = leg.value as? String ?? ""
                return !value.contains("Finding a path") && !value.contains("No route found")
            }
            let climb = header.value as? String ?? ""
            return routed && climb.contains("of climb") && !climb.contains("measuring")
        }
        XCTAssertTrue(
            arrived,
            """
            the walked route and its climb should arrive — the header said \
            \(String(describing: header.value)). No climb means no Stadia key in \
            OpenHikes/Secrets.plist.
            """
        )
    }
}
