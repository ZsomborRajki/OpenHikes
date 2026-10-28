//
//  ScreenshotUITests.swift
//  OpenHikesUITests
//
//  The App Store screenshots, captured by driving the app rather than by
//  posing it.
//
//  Every frame below is the shipping screen, reached the way a hiker reaches
//  it, filled by the launch fixtures `AppLaunchEnvironment` already parses for
//  the functional suites. Nothing here draws a mock: the route is a real
//  OpenStreetMap relation with real heights on it, the statistics are computed
//  by `RouteProfile`, the nearby list is the real merge of published hikes and
//  waymarked routes, and the photographs go in through `HikePhotoImport`. A
//  screenshot that needed a special code path would be a picture of something
//  the customer cannot get to.
//
//  **This class is deliberately absent from `suites` in
//  `Scripts/run-ui-tests.sh`,** for the reason `measurement_tests` is excluded
//  from `--all`: it asserts almost nothing and exists to produce files.
//  `Scripts/screenshots-light.sh` and `Scripts/screenshots-dark.sh` name it
//  explicitly, and they are the only things that should run it — they set the
//  status bar, the device, the photo library and the location grant the
//  frames below assume.
//
//  ## Why the assertions are thin but not absent
//
//  A screenshot run that silently captured the wrong screen would hand over a
//  folder of plausible PNGs, and the mistake would be found in App Review. So
//  each frame waits for something that only exists on the screen it is meant
//  to be, and fails the run rather than shooting whatever was there. The
//  waits are the assertion; the capture is the output.
//

import CoreLocation
import XCTest

nonisolated final class ScreenshotUITests: XCTestCase {
    @MainActor private var resolvedDisplay: ScreenshotDisplay?

    /// How many times ``revealCommunityPins(in:atLeast:)`` re-measures and
    /// pans before giving up.
    private static let centeringPasses = 5

    /// How many community pins the nearby frame has to have on screen. Two,
    /// because one pin says "a hike is here" and two say "the list and the map
    /// are the same answer", which is what the screen is for.
    private static let minimumVisiblePins = 2

    /// Where the walk's middle is aimed, as a share of the screen width.
    ///
    /// Centred. It was biased left for a while, to rescue a trailhead that
    /// kept hanging off the right edge — which turned out to be a pinch
    /// turning the map a few degrees off north rather than anything about
    /// where the pins are. See ``zoomMapInOneStep(in:)``.
    private static let heroRouteCenterX: CGFloat = 0.5

    /// Where the walk's middle is aimed, as a share of the screen height.
    /// A little above centre. The callout is drawn above its pin and wants
    /// the room, but the collapsed sheet only takes the last tenth — and
    /// aiming at 0.55 or 0.46 left the walk low, its finish among the camera
    /// buttons; 0.385 pushed the trailhead up under the status bar.
    private static let heroRouteCenter: CGFloat = 0.42
    /// Close enough to centred to leave alone, as a share of the screen. A
    /// drag is not pixel-exact, so a pass that chased the last percent would
    /// spend a gesture to move the map by nothing.
    private static let centeringTolerance: CGFloat = 0.012
    /// Where a map-panning drag starts: clear of the pins, the sheet and the
    /// map controls in every corner.
    private static let dragAnchor = (dx: CGFloat(0.72), dy: CGFloat(0.30))
    /// Where the hero frame double-taps to zoom: level with the walk's middle
    /// and a fifth of the screen east of it, which is open water on the
    /// Königssee — nothing there for the tap to select. Off the line on
    /// purpose, because a tap on the drawn route opens its hike.
    private static let zoomTapPoint = CGVector(dx: heroRouteCenterX + 0.2, dy: heroRouteCenter)

    /// Long enough for the drag to be taken as a drag rather than a tap.
    private static let dragPressDuration = 0.1
    /// Near the bottom edge, so the sheet is dragged past the middle detent
    /// rather than to it.
    private static let dragTarget = 0.95
    /// How far down the screen the collapsed sheet's top edge has to be. The
    /// compact detent is 80 points against a screen of over 800, so anything
    /// below four fifths is unambiguously it.
    private static let collapsedSheetFraction = 0.8

    // MARK: - Frames

    /// The hero: the whole trail on the map, the sheet out of the way, and one
    /// photograph opened where it was taken.
    ///
    /// The order of the three gestures is forced and not a matter of taste.
    /// *Zoom* lives inside the sheet, so the route has to be framed **before**
    /// the sheet goes to the bottom — afterwards the button is off-screen.
    /// The pin is tapped **after** the sheet is down, because the callout is
    /// drawn above the pin and a sheet at its middle detent covers the half of
    /// the map the lower pins stand in.
    ///
    /// The pins only exist while the detail screen is open — `HikePhotoSection`
    /// is what hands them to the map — and collapsing a sheet does not dismiss
    /// it, which is what lets this frame have both the pins and the map.
    @MainActor
    func testCapturesTrailWithPhotoPins() throws {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-weather",
            Self.routeHueArgument,
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        try importDiscoveredPhotos(in: app, selecting: Self.pinnedPhotoIndexes)

        let zoom = app.buttons[screenshotText("Zoom")]
        XCTAssertTrue(
            scrollIntoView(zoom, in: app),
            "the detail screen should offer to frame the whole route"
        )
        zoom.tap()
        collapseSheet(in: app)

        let pin = element("photo-pin", in: app)
        XCTAssertTrue(
            pin.waitForExistence(timeout: UITestTimeout.navigation),
            "an anchored photograph should stand on the map where it was taken"
        )
        expandRouteIntoTheFreedSpace(in: app)

        // The callout is drawn *above* its pin, so it is opened on the
        // topmost: the trailhead's, where what it covers is the village the
        // walk sets out from. Opened halfway down, it hid the climb to the
        // alm — the stretch the whole frame is of — and a pin poked out over
        // its top edge.
        let pins = photoPins(in: app)
        XCTAssertFalse(pins.isEmpty, "the map should be showing photo pins")
        // The topmost callout makes MapKit pan a landscape Duo's route off
        // the bottom. The next photograph has room above it in that layout.
        let chosen = element("map-side-panel", in: app).exists ? pins.dropFirst().first ?? pins[0] : pins[0]
        chosen.tap()
        XCTAssertTrue(
            element("photo-pin-preview", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "selecting a photo pin should open a callout previewing the photo"
        )
        capture(as: .route, of: app)
    }

    /// The photographs, pinned where they were taken.
    ///
    /// Through the real library and the real matcher, not
    /// `--ui-test-seed-photos`: that fixture draws gradients and scattered
    /// shapes on purpose — it was built to give a decode something
    /// incompressible to measure — and a store listing needs photographs of a
    /// mountain. `Scripts/screenshots.sh` puts stamped JPEGs in the
    /// simulator's library and grants access to it before this runs, so what
    /// the sheet offers here is what `LibraryPhotoMatch` made of them.
    ///
    /// Deliberately no `--ui-test-photo-library`: that argument installs the
    /// stand-in library, which is the right thing for every other suite in
    /// this bundle and exactly wrong here.
    @MainActor
    func testCapturesPhotosAlongTheTrail() throws {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-weather",
            Self.routeHueArgument,
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        try importDiscoveredPhotos(in: app)
        // The tracker to the alm, so the chart points at somewhere and the
        // progress card under it has a distance to report.
        selectChartProgress(48, in: app)
        positionScreenshotGallery(in: app)
        capture(as: .photos, of: app)
    }

    /// The nearby list: published hikes and waymarked OpenStreetMap routes in
    /// one answer, with the pins that say where they are.
    ///
    /// `--ui-test-expanded-sheet` rests the sheet at its *middle* detent, and
    /// that is the whole of the sheet handling this frame needs: the
    /// *My Hikes | Community* picker only exists once the sheet is past its
    /// compact detent, and the middle detent still leaves the top half of the
    /// screen as map for the pins to stand in. The frame is not dragged any
    /// lower deliberately — the list is most of what this screenshot is of,
    /// and ``revealCommunityPins(in:atLeast:)`` pans the pins into the band
    /// above the sheet rather than making the band bigger. Beside the side
    /// panel, in a window wider than tall, the same pan aims at the map the
    /// panel leaves open.
    ///
    /// The `showcase` database rather than the seeded one the suites use:
    /// theirs draws straight steps and squares a test can predict, which on a
    /// map of real paths is exactly what reads as fake. This one's lines are
    /// mapped paths around the Königssee — see `SeededCommunityShowcase.swift`
    /// — and the hiker is put in Schönau beside them.
    @MainActor
    func testCapturesNearbyTrails() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-community=\(SeededCommunityScenario.showcase.rawValue)",
        ])
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.schoenau)
        defer { XCUIDevice.shared.location = nil }
        launch(app)
        prepareNearbyLandscapeMap(in: app)
        selectCommunityTab(in: app)
        let anyRow = app.descendants(matching: .any)
            .matching(identifier: "community-hike-row")
            .firstMatch
        XCTAssertTrue(
            awaitCommunityAnswer(anyRow, in: app),
            "the nearby search never answered with a row to photograph"
        )
        frameCommunityPins(in: app)
        revealCommunityPins(in: app, atLeast: Self.minimumVisiblePins)
        settleScreenshotMapTiles(in: app, rejectSmallLoadingPatches: true)
        capture(as: .nearby, of: app)
    }

    /// A finished walk in the trail's History.
    ///
    /// The summary of a walk that finished the whole trail.
    ///
    /// Two walks are seeded and the newer — the one that covered all of it —
    /// is the row this opens, so the summary leads with 100%. The second
    /// exists so the History list behind it is a history rather than a single
    /// row, which is what the back gesture returns to.
    @MainActor
    func testCapturesWalkHistory() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-seed-walks=FullLoop,HalfLoop",
            Self.routeHueArgument,
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        app.segmentedControls["walk-segment"].buttons[screenshotText("History")].tap()
        let row = app.descendants(matching: .any)
            .matching(identifier: "walk-row")
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTimeout.existence),
            "the seeded walk should be listed in History"
        )
        row.tap()
        XCTAssertTrue(
            app.navigationBars[screenshotText("Hike Summary")].waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "tapping a walk row should push its summary"
        )
        XCTAssertTrue(
            element("walk-completion", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the summary should lead with how much of the trail was covered"
        )
        capture(as: .walkHistory, of: app)
    }
}

/// The gestures and lookups the frames above are built from.
///
/// An extension in the same file rather than a second file, which is what
/// `single_test_class` and `type_body_length` between them leave: the class
/// itself is at the 300-line limit, and these are its members — `private`
/// still reaches the class's own state from here.
extension ScreenshotUITests {
    // MARK: - Support

    // Here rather than in the class body, where `test_case_accessibility`
    // would have them private: the frames in the other
    // `ScreenshotUITests+*.swift` files read them from their own.

    /// Written beside the run so `Scripts/screenshots.sh` can lift them out of
    /// the `.xcresult` by name. Numbered because App Store Connect orders
    /// screenshots by upload order, and the first three are the ones that
    /// appear in search results.
    enum Frame: String, CaseIterable {
        case route = "01-trail-and-its-photos"
        case photos = "02-photos-along-the-trail"
        case nearby = "03-nearby-trails"
        case following = "04-following-the-trail"
        case recording = "05-recording-a-hike"
        case maps = "06-a-map-for-the-mountains"
        case walkHistory = "07-walk-summary"
        case trailMaker = "08-draw-your-own-trail"
        case place = "09-a-place-and-its-photos"
        case share = "10-share-a-hike"
    }

    /// The fixture route: OpenStreetMap relation 222517, heights from Stadia,
    /// a synthesised walking clock. See the file's `<metadata>`.
    static let routeFixture = "KoenigsseeRinnkendlsteig"
    /// The `<trk><name>` the fixture imports under — `GPXImport` titles a hike
    /// from the first track's name, so this and the file have to agree.
    static let routeTitle = "Königssee – Kühroint – Rinnkendlsteig – St. Bartholomä"

    /// One colour for the walk in every frame that imports it — see
    /// `AppLaunchEnvironment.routeHue`. Indigo: a hue none of the route's own
    /// steepness colours come near, from green through red to black, so the
    /// photo pins and the start dot stand off the line rather than into it.
    static let routeHueArgument = "--ui-test-route-hue=0.68"

    /// The middle of Schönau am Königssee, where the frames that need a hiker
    /// somewhere put them: beside the landing, at the foot of the walk.
    static let schoenau = CLLocationCoordinate2D(latitude: 47.592975, longitude: 12.987199)

    /// Which of the stamped photographs the two full-map frames pin to it.
    ///
    /// Four rather than all of them, spread across the walk. The stamper
    /// spaces every photograph it is given evenly along the track, so eight of
    /// them at the zoom that fits a ten-kilometre route draw as one unbroken
    /// column of markers — and the trail the frame is *of* is behind it. Four
    /// leaves the line showing between them and still reads as "photographs
    /// all along the walk". They are also what the framing measures: the line
    /// is drawn rather than exposed, and the pins are the part of it XCUITest
    /// can see.
    static let pinnedPhotoIndexes = [0, 2, 5, 7]

    /// Whether `Scripts/screenshots.sh` seeded this simulator's photo library
    /// and granted access to it.
    ///
    /// Told rather than discovered, and the telling is the point.
    /// `Screenshots/Stamped` holds the hiker's own photographs and is
    /// deliberately not in the repository — see `.gitignore` and
    /// `Screenshots/README.md` — so the three frames that drive the real
    /// library have a fixture that most machines running this bundle do not
    /// have. Without this they failed there: a bare `xcodebuild test`, or
    /// ⌘U in Xcode, went red on a missing photograph rather than on
    /// anything the branch had done.
    ///
    /// A *skip* rather than a softer assertion, because the alternative is
    /// worse in the other direction: a test that quietly passes when its
    /// fixture is absent is a frame that stops being checked the day the
    /// library stops being seeded. `TEST_RUNNER_` is xcodebuild's own prefix
    /// for this — it strips it and hands the rest to the runner — so the
    /// script says *yes* and nothing else can.
    static var hasStampedLibrary: Bool {
        ProcessInfo.processInfo.environment["OPENHIKES_STAMPED_LIBRARY"] == "1"
    }

    /// What a machine without the fixture is told, which is how to get it.
    static let noStampedLibrary = """
        No stamped photo library on this simulator. These frames import \
        photographs through the real library, which \
        Scripts/screenshots.sh seeds from Screenshots/Stamped before it runs \
        them — a directory the repository does not carry. Run them through \
        that script rather than on their own.
        """

    /// Attaches the stamped library photographs to the open hike, through the
    /// real discovery sheet.
    ///
    /// Not `--ui-test-seed-photos`: that fixture draws gradients and scattered
    /// shapes on purpose — it was built to give a decode something
    /// incompressible to measure — and a store listing needs photographs of a
    /// mountain. `Scripts/screenshots.sh` puts stamped JPEGs in the
    /// simulator's library and grants access to it before this runs, so what
    /// the sheet offers here is what `LibraryPhotoMatch` made of them.
    @MainActor
    func importDiscoveredPhotos(
        in app: XCUIApplication,
        selecting indexes: [Int] = []
    ) throws {
        try XCTSkipUnless(Self.hasStampedLibrary, Self.noStampedLibrary)
        let discover = element("photo-discovery-button", in: app)
        XCTAssertTrue(
            scrollIntoView(discover, in: app),
            "a hike with a timed route should offer to look for photos of it"
        )
        discover.tap()

        let grid = element("photo-discovery-grid", in: app)
        XCTAssertTrue(
            grid.waitForExistence(timeout: UITestTimeout.trace),
            "the stamped photographs should be offered for review — check that "
                + "Scripts/screenshots.sh added them and granted photo access"
        )
        XCTAssertTrue(
            element("discovered-photo-0", in: app).exists,
            "and each of them should be a reviewable tile"
        )
        // Empty means "whatever the sheet already has selected", which is all
        // of them — an empty array rather than an optional one, which
        // `discouraged_optional_collection` forbids and which would say the
        // same thing here anyway.
        if !indexes.isEmpty {
            // The sheet opens with everything selected, so the subset is
            // reached by clearing and re-picking rather than by unpicking the
            // rest — one gesture instead of "all but four", and it does not
            // change meaning when the library gains a photograph.
            element("photo-discovery-select-all-button", in: app).tap()
            for index in indexes {
                let tile = element("discovered-photo-\(index)", in: app)
                XCTAssertTrue(
                    tile.waitForExistence(timeout: UITestTimeout.existence),
                    "photo \(index) should be among the matches"
                )
                tile.tap()
            }
        }
        element("photo-discovery-add-button", in: app).tap()

        // A partial selection leaves the sheet standing, and that is the
        // sheet behaving correctly: it dismisses itself only when the import
        // emptied `matches`, so taking four of eight leaves four still worth
        // reviewing. Everything behind it — the Zoom button the hero frame
        // needs — is unreachable until it is closed.
        if !indexes.isEmpty {
            let done = element("photo-discovery-done-button", in: app)
            XCTAssertTrue(
                done.waitForExistence(timeout: UITestTimeout.navigation),
                "a partial import should leave the sheet up, with a way out"
            )
            done.tap()
        }

        XCTAssertTrue(
            element("hike-photo-strip", in: app)
                .waitForExistence(timeout: UITestTimeout.trace),
            "adding the matches should file them into the hike's gallery"
        )
    }

    /// Pulls the map back until at least `atLeast` community pins are standing
    /// in the open map — see ``openMapArea(in:)``.
    ///
    /// A loop, because one pan does not settle it: each pass moves the map,
    /// which changes which annotations MapKit has views for, which changes the
    /// box the next pass measures. Panning towards the measured middle
    /// converges; two fixed passes did not, and overshot to nothing on screen.
    ///
    /// Zooming out here was tried
    /// and made things worse: `XCUIElement.pinch` pivots on the element's
    /// centre, the map element spans the whole window, and once the sheet has
    /// been dragged down that centre is *on the sheet* — so every "zoom out"
    /// dragged the sheet back to full height and hid the map it was trying to
    /// reveal.
    ///
    /// What makes the pins visible instead is the fixture: the seeded hikes
    /// used to start within ninety metres of each other and these pins are
    /// allowed to declutter — see `MapCommunityAnnotations.swift` — so all
    /// three drew as one marker. They are spread a kilometre apart now. See
    /// `SeededCommunityTransport.listingSpreadLatitude`.
    @MainActor
    private func revealCommunityPins(in app: XCUIApplication, atLeast minimum: Int) {
        for _ in 0..<Self.centeringPasses {
            if visibleCommunityPins(in: app).count >= minimum { return }
            centerCommunityPins(in: app)
        }
        if visibleCommunityPins(in: app).count >= minimum { return }
        let total = app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .allElementsBoundByIndex
        XCTFail(
            "the map never showed \(minimum) community pins clear of the sheet or the panel"
                + " — \(visibleCommunityPins(in: app).count) of"
                + " \(total.count) pin(s) were in the picture"
        )
    }

    /// How many steps out the nearby frame takes from where the map opens on
    /// the hiker: one, from the streets of Schönau to the end of the lake,
    /// which is the scale a walk up to the alm and one round the landing both
    /// read at. Two put the whole valley on screen and the lines went thin.
    static let nearbyZoomOutSteps = 1

    /// The walks the nearby frame centres on, by the titles the `showcase`
    /// database gives them. Its two waymarked routes are pinned at the middle
    /// of their own lines, kilometres off to the west and the south-east, and
    /// framing all four put the northmost pin under *Search this area*.
    static let nearbyWalkTitles = ["Kührointalm and Back", "Malerwinkel Loop"]

    /// Zooms the map out around a community pin, with MapKit's own two-finger
    /// tap, and pans the published walks' pins into the middle of the open
    /// map, with their lines running south from them.
    ///
    /// On a pin rather than on the map, because the map element spans the
    /// window and its centre is under the sheet — the reason the pinch was
    /// given up above. A pin stands in the band above it, and the tap reaches
    /// the map's own recognizer through it; a two-finger tap selects nothing.
    /// A tap rather than a pinch for the reason the hero frame gives: it
    /// zooms and does not turn the map.
    ///
    /// Not on an open iPhone Duo, where the app is on a screen that is not
    /// `XCUIScreen.main`. XCUITest measures a two-finger gesture against the
    /// main screen's windows as well, and there that is the folded-away cover
    /// display: a window of its size over the inner display's top-leading
    /// corner, which left the pins there too little unoccluded room for two
    /// fingers, and the gesture failed every time. The inner display shows
    /// half as much map again as the 6.9" phone without the step.
    @MainActor
    func frameCommunityPins(in app: XCUIApplication) {
        let zoomOutSteps = screenshotDisplay(in: app).screen == XCUIScreen.main ? Self.nearbyZoomOutSteps : 0
        for _ in 0..<zoomOutSteps {
            guard let pin = visibleCommunityPins(in: app).first else { return }
            pin.twoFingerTap()
        }
        // Once. A second pass is a correction of a few points, short enough
        // for the map to take as a tap — and a tap on a line opens that hike,
        // which is how one run photographed AV Weg 493's screen instead.
        centerCommunityPins(in: app, titled: Self.nearbyWalkTitles)
    }

    /// Pans the map so the community pins — or the ones with `titles`, when it
    /// is given — sit in the middle of the open map: see ``openMapArea(in:)``.
    ///
    /// They are not there on their own. The sheet rests at its middle detent
    /// here and the pins landed six points *under* its top edge — on the map,
    /// in the tree, and not in the picture. The same measured pan the hero
    /// frame uses on the photo pins, aimed at the middle of the open map
    /// rather than at the middle of the screen, because half the screen is
    /// sheet — or, in a window wider than tall, a third of it is panel.
    @MainActor
    private func centerCommunityPins(in app: XCUIApplication, titled titles: [String] = []) {
        let map = mapElement(in: app)
        let window = windowFrame(of: app)
        let area = openMapArea(in: app)
        let pins = app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .allElementsBoundByIndex
            .filter { pin in titles.isEmpty || titles.contains { pin.label.hasSuffix($0) } }
        guard let bounds = Self.bounds(of: pins), window.height > 0, area.height > 0 else { return }

        let dx = (area.midX - bounds.midX) / window.width
        let dy = (area.midY - bounds.midY) / window.height
        guard abs(dx) > Self.centeringTolerance || abs(dy) > Self.centeringTolerance else { return }

        // The anchor has to be in the open map too: a drag that starts on the
        // sheet drags the sheet.
        let anchor = CGPoint(x: area.minX + area.width * 0.75, y: area.minY + area.height * 0.6)
        let margin = CGSize(width: window.width * 0.05, height: window.height * 0.05)
        let landing = CGPoint(
            x: min(max(anchor.x + dx * window.width, area.minX + margin.width), area.maxX - margin.width),
            y: min(max(anchor.y + dy * window.height, area.minY + margin.height), area.maxY - window.height * 0.02)
        )
        coordinate(at: anchor, on: map)
            .press(forDuration: Self.dragPressDuration, thenDragTo: coordinate(at: landing, on: map))
    }

    /// The community pins that are actually on screen, in the open map.
    ///
    /// `exists` is not the question: an annotation the map has scrolled off,
    /// or one behind the sheet, is in the tree and is not in the picture.
    @MainActor
    private func visibleCommunityPins(in app: XCUIApplication) -> [XCUIElement] {
        let area = openMapArea(in: app)
        return app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .allElementsBoundByIndex
            .filter { pin in
                let frame = pin.frame
                return frame.minX > area.minX && frame.maxX < area.maxX
                    && frame.minY > area.minY && frame.maxY < area.maxY
            }
    }

    /// The part of the window where the map shows with nothing over it:
    /// beside the side panel, which is what a window wider than tall draws the
    /// sheet's contents as, and above the sheet otherwise.
    ///
    /// A sheet that cannot be found must not silently mean "the map is a
    /// zero-height strip at the top", which is what reading `.frame` off a
    /// missing element gives — and which filters out every pin on screen
    /// while looking exactly like a map that has none.
    @MainActor
    func openMapArea(in app: XCUIApplication) -> CGRect {
        let window = windowFrame(of: app)
        let panel = element("map-side-panel", in: app)
        if panel.exists, panel.frame.width > 0 {
            let panelEdge = panel.frame.maxX
            return CGRect(x: panelEdge, y: window.minY, width: window.maxX - panelEdge, height: window.height)
        }
        let sheet = element("map-sheet", in: app)
        let sheetTop = sheet.exists && sheet.frame.height > 0 ? sheet.frame.minY : window.maxY
        return CGRect(x: window.minX, y: window.minY, width: window.width, height: sheetTop - window.minY)
    }

    /// Whether the sheet's contents stand beside the map, as a panel at the
    /// window's full height, rather than over it as a sheet with detents.
    @MainActor
    private func isPanelBesideTheMap(in app: XCUIApplication) -> Bool {
        element("map-side-panel", in: app).exists
    }

    /// `point`, in the window, as a coordinate of `element`: absolute, where a
    /// normalized offset is a share of whatever size `element` is.
    @MainActor
    func coordinate(at point: CGPoint, on element: XCUIElement) -> XCUICoordinate {
        let frame = element.frame
        return element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY))
    }

    /// The box `pins` occupy, ignoring the ones that are not really anywhere.
    ///
    /// MapKit does not lay out an annotation view for an annotation that is
    /// well off screen, and XCUITest reports those as a zero rect at the
    /// origin. Unioned in, one of them drags the box up to the top-left
    /// corner — so a pan that aims the box's middle at the middle of the map
    /// aims at a point no pin is near, which is how this frame ended up with
    /// one pin on screen instead of three.
    @MainActor
    private static func bounds(of pins: [XCUIElement]) -> CGRect? {
        let real = pins.map(\.frame).filter { $0.width > 0 && $0.height > 0 }
        guard let first = real.first else { return nil }
        return real.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The map itself, for the gestures that frame it.
    ///
    /// `MKMapView` is exposed as an `.map` element; taking it by type rather
    /// than by identifier because the pinches below need the map's own centre,
    /// and pinching the application element would pivot around a point the
    /// sheet is sitting on.
    @MainActor
    func mapElement(in app: XCUIApplication) -> XCUIElement {
        let map = app.maps.firstMatch
        XCTAssertTrue(
            map.waitForExistence(timeout: UITestTimeout.navigation),
            "the map should be on screen"
        )
        return map
    }

    /// Zooms the map in by one step, with MapKit's own double tap.
    ///
    /// Not `XCUIElement.pinch`. A pinch is a two-finger gesture and MapKit
    /// reads a little rotation out of it, which is not cosmetic here: turned
    /// a few degrees, a walk six kilometres north-to-south and under two wide
    /// draws as a diagonal that fits the frame at no zoom. This frame used to
    /// pinch, then tap MapKit's compass to turn the map back, then pan twice
    /// more to recover what the turn had moved — three gestures spent undoing
    /// one. A double tap zooms and does nothing else, so there is nothing to
    /// undo, and the assertion below says so rather than quietly correcting it.
    @MainActor
    private func zoomMapInOneStep(in app: XCUIApplication) {
        mapElement(in: app).coordinate(withNormalizedOffset: Self.zoomTapPoint).doubleTap()
        XCTAssertFalse(
            screenshotCompass(in: app).waitForExistence(timeout: UITestTimeout.brief),
            "zooming should leave the map north-up — MapKit shows its compass only when it is not"
        )
    }

    /// Re-frames the route to use the space collapsing the sheet just freed.
    ///
    /// The app cannot be asked to do this, and that is a deliberate design
    /// rather than a gap: every camera move measures the sheet at its *middle*
    /// detent — see `MapCoordinator+RouteFitting.swift` — and every path that
    /// moves the camera puts the sheet there first. So *Zoom* fits the route
    /// into the strip above a half-height sheet, which on this device is 80 pt
    /// of padding either side of a 251 pt window: about a quarter of the
    /// screen. Correct for the app, too small for a hero frame.
    ///
    /// Pan, zoom, pan. The route ends up a fifth of the way down, and a zoom
    /// doubles every distance from the point it is anchored on — so zooming
    /// first drives the line off the top edge. The route's middle is panned
    /// to where the frame wants it, the map zoomed one step beside it, and
    /// the doubled offset that leaves is panned back out.
    ///
    /// Beside the map there is nothing to expand into. A window wider than
    /// tall draws the sheet's contents as a panel at its full height, which
    /// *Zoom* already fits the route beside — the panel is the one thing the
    /// focus area measures there — so the route has the whole open map, and
    /// one more step would push its ends off it.
    @MainActor
    func expandRouteIntoTheFreedSpace(in app: XCUIApplication) {
        if isPanelBesideTheMap(in: app) {
            positionLandscapeHikeHeader(in: app)
            return
        }
        centerPhotoPins(in: app)
        zoomMapInOneStep(in: app)
        // Up to twice, because a drag lands short of the vector it is given,
        // so one correction only closes part of the gap. A pass inside
        // ``centeringTolerance`` spends no gesture.
        centerPhotoPins(in: app)
        centerPhotoPins(in: app)
    }

    /// This hike's photo pins, top to bottom.
    @MainActor
    private func photoPins(in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(identifier: "photo-pin")
            .allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    /// Pans the map so the photo pins — which stand along the route, and are
    /// the only part of it XCUITest can measure — sit in the middle of it.
    ///
    /// Measured rather than assumed. The first version of this panned by a
    /// constant worked out from the fit's own arithmetic, and it was wrong in
    /// practice: it left the walk in the bottom-left corner, because a drag
    /// does not move the map by exactly the vector it is given and the error
    /// is then multiplied by the zoom.
    ///
    /// The drag starts from an empty corner of the map rather than from the
    /// pins themselves: a press that begins on a pin drags the pin's callout
    /// rather than the map under it.
    @MainActor
    private func centerPhotoPins(in app: XCUIApplication) {
        let map = mapElement(in: app)
        guard let bounds = Self.bounds(of: photoPins(in: app)) else { return }
        let screen = windowFrame(of: app)
        guard screen.width > 0, screen.height > 0 else { return }

        let dx = Self.heroRouteCenterX - bounds.midX / screen.width
        let dy = Self.heroRouteCenter - bounds.midY / screen.height
        guard abs(dx) > Self.centeringTolerance || abs(dy) > Self.centeringTolerance else { return }

        let from = CGVector(dx: Self.dragAnchor.dx, dy: Self.dragAnchor.dy)
        let to = CGVector(
            dx: min(max(Self.dragAnchor.dx + dx, 0.05), 0.95),
            dy: min(max(Self.dragAnchor.dy + dy, 0.05), 0.7)
        )
        map.coordinate(withNormalizedOffset: from)
            .press(
                forDuration: Self.dragPressDuration,
                thenDragTo: map.coordinate(withNormalizedOffset: to)
            )
    }

    /// Drags the sheet down to its compact detent and waits for it to land.
    ///
    /// A detent is not something XCUITest can read, so the wait is a frame:
    /// the compact height is a small fraction of the screen, and a sheet whose
    /// top edge is down in the bottom fifth is at it. The same test
    /// `PhotoUITests` makes, which cannot be borrowed — its helpers are an
    /// `extension PhotoUITests`, deliberately, so `--suite PhotoUITests` still
    /// selects the whole class.
    @MainActor
    func dragSheet(in app: XCUIApplication, to target: CGFloat) {
        let grabber = screenshotSheetGrabber(in: app)
        XCTAssertTrue(
            grabber.waitForExistence(timeout: UITestTimeout.navigation),
            "the sheet should offer a grabber to drag"
        )
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: Self.dragPressDuration,
                thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: target)
                )
            )
    }

    /// Collapses the sheet — and does nothing beside the map, where the
    /// sheet's contents are a panel with no detents and no grabber, standing
    /// at the window's full height beside a map that is already all open.
    @MainActor
    func collapseSheet(in app: XCUIApplication) {
        if isPanelBesideTheMap(in: app) { return }
        dragSheet(in: app, to: Self.dragTarget)
        let sheet = element("map-sheet", in: app)
        let window = windowFrame(of: app)
        let collapsed = NSPredicate { _, _ in
            sheet.frame.minY > window.height * Self.collapsedSheetFraction
        }
        let settled = expectation(for: collapsed, evaluatedWith: sheet)
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: UITestTimeout.navigation),
            .completed,
            "the sheet should have come to rest at its compact detent"
        )
    }

    /// Attaches the screen `app` is showing on to the result bundle under
    /// `frame`'s name.
    ///
    /// A screen rather than `app.screenshot()`, because the app's own
    /// screenshot is clipped to the app's frame and loses the status bar —
    /// and that is a part of the picture App Store Connect expects to be
    /// there. The app is asked only which screen that is.
    @MainActor
    func capture(as frame: Frame, of app: XCUIApplication) {
        switch frame {
        case .route, .nearby, .following, .recording, .maps, .trailMaker:
            settleScreenshotMapTiles(in: app)
        case .photos, .walkHistory, .place, .share:
            break
        }
        attachScreenshotEvidence(named: frame.rawValue, in: app)
    }

    /// The screen whose size is the app's window's.
    ///
    /// `XCUIScreen.main` on every iPhone but one. An iPhone Duo has two
    /// screens, and `main` is its cover display whether the device is closed
    /// or open — so a frame shot from it with the device open is black. The
    /// window is measured rather than `app.frame`, which on the Duo's inner
    /// display keeps that display's portrait size after it has turned.
    @MainActor
    func screenshotDisplay(in app: XCUIApplication) -> ScreenshotDisplay {
        let window = app.windows.firstMatch
        let size = window.exists ? window.frame.size : app.frame.size
        if let resolvedDisplay, resolvedDisplay.windowSize == size { return resolvedDisplay }
        for screen in XCUIScreen.screens {
            let image = screen.screenshot().image
            if abs(image.size.width - size.width) <= 1, abs(image.size.height - size.height) <= 1 {
                let display = ScreenshotDisplay(screen: screen, image: image, windowSize: size)
                resolvedDisplay = display
                return display
            }
        }
        let display = ScreenshotDisplay(screen: .main, image: XCUIScreen.main.screenshot().image, windowSize: size)
        resolvedDisplay = display
        return display
    }
}
