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
//  `Scripts/screenshots.sh` names it explicitly, and that script is the only
//  thing that should run it — it is what sets the status bar, the device and
//  the photo library the frames below assume.
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
    /// The fixture route: OpenStreetMap relation 222517, heights from Stadia,
    /// a synthesised walking clock. See the file's `<metadata>`.
    private static let routeFixture = "KoenigsseeRinnkendlsteig"
    /// The `<trk><name>` the fixture imports under — `GPXImport` titles a hike
    /// from the first track's name, so this and the file have to agree.
    private static let routeTitle =
        "Königssee – Kühroint – Rinnkendlsteig – St. Bartholomä"

    /// The fixture route's first `<trkpt>`, which is the Königssee boat
    /// landing the walk starts from.
    private static let trailhead = CLLocationCoordinate2D(
        latitude: 47.599436,
        longitude: 12.984916
    )

    /// The route's opening stretch, interpolated along the fixture's own line
    /// at 22 m — on the trail rather than near it, so the recorded line sits
    /// where the map draws the path.
    ///
    /// Twenty of them, 418 m in all, and the length is the point: the frame is
    /// *of* the line the recorder has drawn so far, and six fixes covering a
    /// hundred metres is a smear a reader cannot see at the zoom the recording
    /// map sits at. It costs the walk's own time — the fixes go in at
    /// ``UITestFixture/paceSeconds`` because that is what the recorder accepts
    /// — which is why this is the slowest frame in the set.
    ///
    /// 22 m and not the fixture's own point spacing, which runs to 40 m in
    /// places. At ``UITestFixture/paceSeconds`` a 40 m step is 36 km/h, and
    /// `RecordingFixPolicy` throws it out as a sprint — which arrives as
    /// "the recorder never accepted fix 3" rather than as anything about
    /// speed. It is the same 22 m ``UITestFixture/trailPoints`` uses, for the
    /// same reason.
    private static let openingStretch = [
        trailhead,
        CLLocationCoordinate2D(latitude: 47.599327, longitude: 12.984674),
        CLLocationCoordinate2D(latitude: 47.599147, longitude: 12.984559),
        CLLocationCoordinate2D(latitude: 47.598960, longitude: 12.984463),
        CLLocationCoordinate2D(latitude: 47.598773, longitude: 12.984367),
        CLLocationCoordinate2D(latitude: 47.598586, longitude: 12.984271),
        CLLocationCoordinate2D(latitude: 47.598400, longitude: 12.984173),
        CLLocationCoordinate2D(latitude: 47.598213, longitude: 12.984076),
        CLLocationCoordinate2D(latitude: 47.598029, longitude: 12.983970),
        CLLocationCoordinate2D(latitude: 47.597845, longitude: 12.983861),
        CLLocationCoordinate2D(latitude: 47.597668, longitude: 12.983729),
        CLLocationCoordinate2D(latitude: 47.597494, longitude: 12.983590),
        CLLocationCoordinate2D(latitude: 47.597320, longitude: 12.983452),
        CLLocationCoordinate2D(latitude: 47.597146, longitude: 12.983311),
        CLLocationCoordinate2D(latitude: 47.596979, longitude: 12.983153),
        CLLocationCoordinate2D(latitude: 47.596811, longitude: 12.982998),
        CLLocationCoordinate2D(latitude: 47.596642, longitude: 12.982846),
        CLLocationCoordinate2D(latitude: 47.596473, longitude: 12.982694),
        CLLocationCoordinate2D(latitude: 47.596304, longitude: 12.982542),
        CLLocationCoordinate2D(latitude: 47.596134, longitude: 12.982391),
    ]

    /// How many times ``revealCommunityPins(in:atLeast:)`` re-measures and
    /// pans before giving up.
    private static let centringPasses = 5

    /// How many community pins the nearby frame has to have on screen. Two,
    /// because one pin says "a hike is here" and two say "the list and the map
    /// are the same answer", which is what the screen is for.
    private static let minimumVisiblePins = 2

    /// Which of the stamped photographs the hero frame pins to the map.
    ///
    /// Four rather than all of them, spread across the walk. The stamper
    /// spaces every photograph it is given evenly along the track, so eight of
    /// them at the zoom that fits a ten-kilometre route draw as one unbroken
    /// column of markers — and the trail the frame is *of* is behind it. Four
    /// leaves the line showing between them and still reads as "photographs
    /// all along the walk".
    private static let pinnedPhotoIndexes = [0, 2, 5, 7]

    /// Where the walk's middle is aimed, as a share of the screen width.
    ///
    /// Centred. It was biased left for a while, to rescue a trailhead that
    /// kept hanging off the right edge — which turned out to be the map being
    /// a few degrees off north rather than anything about where the pins are.
    /// See ``restoreNorth(in:)``.
    private static let heroRouteCentreX: CGFloat = 0.5

    /// Where the walk's middle is aimed, as a share of the screen height.
    /// A little above centre. The callout is drawn above its pin and wants
    /// the room, but the collapsed sheet only takes the last tenth — and
    /// aiming at 0.55 or 0.46 left the walk low, its finish among the camera
    /// buttons; 0.385 pushed the trailhead up under the status bar.
    private static let heroRouteCentre: CGFloat = 0.42
    /// Close enough to centred to leave alone, as a share of the screen. A
    /// drag is not pixel-exact, so a pass that chased the last percent would
    /// spend a gesture to move the map by nothing.
    private static let centringTolerance: CGFloat = 0.012
    /// Where a map-panning drag starts: clear of the pins, the sheet and the
    /// map controls in every corner.
    private static let dragAnchor = (dx: CGFloat(0.72), dy: CGFloat(0.30))
    /// How much the hero frame enlarges the route once the sheet is down.
    /// 2.5 takes the line from roughly a quarter of the screen to about two
    /// thirds of it: the trailhead sits up level with the weather badge and
    /// the finish clears the camera buttons in the bottom corner. This,
    /// ``heroRouteCentreX`` and ``heroRouteCentre`` are the three numbers that
    /// decide how the hero frame sits; nudge them together rather than
    /// separately.
    ///
    /// It only goes this far because the map is put back to north first — see
    /// ``restoreNorth(in:)``. Turned even a few degrees, the walk is wider
    /// than the frame well before this.
    private static let heroZoomIn: CGFloat = 2.5

    /// How far up the recording frame drags its map, as a share of the screen,
    /// to bring the fresh end of the line out from under the sheet.
    private static let recordingLift: CGFloat = 0.2

    /// Long enough for the drag to be taken as a drag rather than a tap.
    private static let dragPressDuration = 0.1
    /// Near the bottom edge, so the sheet is dragged past the middle detent
    /// rather than to it.
    private static let dragTarget = 0.95
    /// How far down the screen the collapsed sheet's top edge has to be. The
    /// compact detent is 80 points against a screen of over 800, so anything
    /// below four fifths is unambiguously it.
    private static let collapsedSheetFraction = 0.8

    /// Written beside the run so `Scripts/screenshots.sh` can lift them out of
    /// the `.xcresult` by name. Numbered because App Store Connect orders
    /// screenshots by upload order, and the first three are the ones that
    /// appear in search results.
    private enum Frame: String, CaseIterable {
        case route = "01-trail-and-its-photos"
        case photos = "02-photos-along-the-trail"
        case nearby = "03-nearby-trails"
        case statistics = "04-statistics-and-profile"
        case recording = "05-recording-a-hike"
        case offline = "06-offline-maps"
        case walkHistory = "07-walk-summary"
        case trailMaker = "08-draw-your-own-trail"
    }

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
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        try importDiscoveredPhotos(in: app, selecting: Self.pinnedPhotoIndexes)

        let zoom = app.buttons["Zoom"]
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

        // The callout is drawn *above* its pin, so it is opened on one from
        // the lower half of the line — opening the topmost would push it off
        // the top edge.
        let pins = photoPins(in: app)
        XCTAssertFalse(pins.isEmpty, "the map should be showing photo pins")
        pins[pins.count / 2].tap()
        XCTAssertTrue(
            element("photo-pin-preview", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "selecting a photo pin should open a callout previewing the photo"
        )
        capture(as: .route)
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
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        try importDiscoveredPhotos(in: app)
        scrollIntoView(element("hike-photo-strip", in: app), in: app)
        capture(as: .photos)
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
    /// above the sheet rather than making the band bigger.
    @MainActor
    func testCapturesNearbyTrails() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)
        let anyRow = app.descendants(matching: .any)
            .matching(identifier: "community-hike-row")
            .firstMatch
        XCTAssertTrue(
            awaitCommunityAnswer(anyRow, in: app),
            "the nearby search never answered with a row to photograph"
        )
        revealCommunityPins(in: app, atLeast: Self.minimumVisiblePins)
        capture(as: .nearby)
    }

    /// The statistics and the elevation profile — the screen that answers
    /// "is this a walk or a day out".
    @MainActor
    func testCapturesStatisticsAndProfile() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        scrollIntoView(element("elevation-chart", in: app), in: app)
        capture(as: .statistics)
    }

    /// A recording in progress.
    ///
    /// The live figures are the whole point of the screen, and a recorder that
    /// has only just started reads zero for every one of them — so this walks
    /// the opening stretch of the fixture route before it shoots, and the
    /// frame shows a distance, a climb and a clock that are all doing
    /// something. The fixes go in at ``UITestFixture/paceSeconds``, which is a
    /// walk rather than a sprint `RecordingFixPolicy` turns down.
    @MainActor
    func testCapturesRecordingAHike() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-weather",
        ])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.trailhead)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence),
            "the recording screen never drew its point count"
        )
        walkRecordedTrace(Self.openingStretch, countedBy: points)
        liftRecordedLineClearOfTheSheet(in: app)
        capture(as: .recording)
    }

    /// Offline maps: a whole route's tiles saved for a walk with no signal.
    ///
    /// Stadia Outdoors has to be selected first, and that is a fact about the
    /// feature rather than a step for the test's convenience. OpenStreetMap's
    /// tile policy forbids bulk download, so on the default provider the
    /// button this frame is *of* does not exist — it is absent rather than
    /// disabled, which `SettingsUITests` asserts from the other direction.
    /// `--ui-test-entitled` grants the Pro entitlement but selects nothing.
    ///
    /// The first version of this frame skipped the selection and shot whatever
    /// the scroll landed on, which was the line-style picker, and the run went
    /// green: `scrollIntoView` reports its failure in a return value that was
    /// being discarded. Hence the assertion below.
    @MainActor
    func testCapturesOfflineMaps() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(Self.routeFixture)",
            "--ui-test-entitled",
        ])
        element("settings-button", in: app).tap()
        let stadia = element("provider-row-stadia_outdoors", in: app)
        XCTAssertTrue(
            stadia.waitForExistence(timeout: UITestTimeout.navigation),
            "an entitled launch should offer Stadia Outdoors — check that "
                + "OpenHikes/Secrets.plist carries a Stadia key"
        )
        stadia.tap()
        app.buttons["Done"].tap()

        openHikeDetail(in: app, titled: Self.routeTitle)
        let download = element("offline-download-button", in: app)
        XCTAssertTrue(
            scrollIntoView(download, in: app),
            "a provider that permits bulk download should offer the button"
        )
        capture(as: .offline)
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
        ])
        openHikeDetail(in: app, titled: Self.routeTitle)
        app.segmentedControls["walk-segment"].buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(identifier: "walk-row")
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTimeout.existence),
            "the seeded walk should be listed in History"
        )
        row.tap()
        XCTAssertTrue(
            app.navigationBars["Hike Summary"].waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "tapping a walk row should push its summary"
        )
        XCTAssertTrue(
            element("walk-completion", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the summary should lead with how much of the trail was covered"
        )
        capture(as: .walkHistory)
    }

    /// Drawing a trail: the one frame in the set that shows the app *making*
    /// something rather than showing something.
    ///
    /// The map is the canvas and the sheet is the drawing, so this is the only
    /// frame that needs both halves of the screen doing work at once — which
    /// is why the sheet stays at its middle detent and the points go down in
    /// the band above it.
    ///
    /// **The legs are straight and that is honest here.** A drawn leg follows
    /// mapped paths by asking Overpass, and no launch running tests may reach
    /// a volunteer-run API — see ``OpenHikesModel/makeTrailMaker(container:trailGraphProvider:)``.
    /// A launch with no graph hides the *Follow Paths* switch rather than
    /// offering one it could not honour, so what this shoots is exactly what a
    /// hiker drawing freehand sees, and nothing in the frame claims otherwise.
    ///
    /// The map is put over the fixture route's trailhead through the
    /// simulator's own location rather than by importing a hike, because
    /// selecting a hike pushes its screen and the maker's pill is offered only
    /// while no screen is pushed.
    @MainActor
    func testCapturesDrawingATrail() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
        ])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.trailhead)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        let map = element("trail-map", in: app)
        XCTAssertTrue(
            map.waitForExistence(timeout: UITestTimeout.navigation),
            "the map should be up before anything is drawn on it"
        )
        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnTrail, on: map, in: app)

        liftDrawnTrailClearOfTheSheet(in: app)
        // The header is the sentence this frame is of — how long the line is
        // so far — and it sits under the search field, which is the section a
        // middle detent opens on.
        XCTAssertTrue(
            scrollIntoView(element("trail-draft-length", in: app), in: app),
            "the maker should show the line's length beside its points"
        )
        capture(as: .trailMaker)
    }

    /// Four taps in the band above a sheet at its middle detent, spread so the
    /// line bends twice rather than running straight across.
    ///
    /// Wider apart than ``TrailMakerUITests``' own offsets: that suite is
    /// asserting that a tap becomes a point, and this one is a picture of a
    /// route somebody planned.
    ///
    /// **The pins do not land where the taps did**, and correcting the offsets
    /// is not the fix. Measured over two captures: the same four taps drew
    /// 0.28, 0.19, 0.14 and about 0.10 of the screen lower than they were
    /// made — a shrinking drift, which is a camera still settling under a map
    /// that has just been given a location rather than a constant to subtract.
    /// So the taps stay where they read well and
    /// ``liftDrawnTrailClearOfTheSheet(in:)`` pans afterwards, which is the
    /// same answer `liftRecordedLineClearOfTheSheet(in:)` gives to the same
    /// problem on the recording frame.
    private static let drawnTrail: [CGVector] = [
        CGVector(dx: 0.26, dy: 0.30),
        CGVector(dx: 0.43, dy: 0.16),
        CGVector(dx: 0.64, dy: 0.25),
        CGVector(dx: 0.80, dy: 0.15),
    ]

    /// How far the drawn line is panned up afterwards, in fractions of the
    /// window. Enough to bring the first point out from behind the sheet
    /// without taking the last one under the status bar.
    private static let drawnTrailLift: CGFloat = 0.18
}

/// The gestures and lookups the frames above are built from.
///
/// An extension in the same file rather than a second file, which is what
/// `single_test_class` and `type_body_length` between them leave: the class
/// itself is at the 300-line limit, and these are its members — `private`
/// still reaches the class's own state from here.
extension ScreenshotUITests {
    // MARK: - Support

    /// Whether `Scripts/screenshots.sh` seeded this simulator's photo library
    /// and granted access to it.
    ///
    /// Told rather than discovered, and the telling is the point.
    /// `Screenshots/Stamped` holds the hiker's own photographs and is
    /// deliberately not in the repository — see `.gitignore` and
    /// `Screenshots/README.md` — so the two frames that drive the real
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
        No stamped photo library on this simulator. These two frames import \
        photographs through the real library and the real matcher, which \
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
    private func importDiscoveredPhotos(
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
    /// in the part of it the sheet is not over.
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
        for _ in 0..<Self.centringPasses {
            if visibleCommunityPins(in: app).count >= minimum { return }
            centreCommunityPins(in: app)
        }
        if visibleCommunityPins(in: app).count >= minimum { return }
        let total = app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .allElementsBoundByIndex
        XCTFail(
            "the map never showed \(minimum) community pins clear of the sheet"
                + " — \(visibleCommunityPins(in: app).count) of"
                + " \(total.count) pin(s) were in the picture"
        )
    }

    /// Pans the map so the community pins sit in the middle of the band the
    /// sheet is not over.
    ///
    /// They are not there on their own. The sheet rests at its middle detent
    /// here and the pins landed six points *under* its top edge — on the map,
    /// in the tree, and not in the picture. The same measured pan the hero
    /// frame uses on the photo pins, aimed at the middle of the visible band
    /// rather than at the middle of the screen, because half the screen is
    /// sheet.
    @MainActor
    private func centreCommunityPins(in app: XCUIApplication) {
        let map = mapElement(in: app)
        let screen = app.frame
        let sheet = element("map-sheet", in: app)
        let bandBottom = sheet.exists && sheet.frame.height > 0
            ? sheet.frame.minY
            : screen.maxY
        let pins = app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .allElementsBoundByIndex
        guard let bounds = Self.bounds(of: pins), screen.height > 0, bandBottom > 0 else { return }

        let dx = 0.5 - bounds.midX / screen.width
        let dy = (bandBottom / 2) / screen.height - bounds.midY / screen.height
        guard abs(dx) > Self.centringTolerance || abs(dy) > Self.centringTolerance else { return }

        // The anchor has to be inside the band too: a drag that starts on the
        // sheet drags the sheet.
        let anchor = CGVector(dx: 0.75, dy: (bandBottom * 0.6) / screen.height)
        map.coordinate(withNormalizedOffset: anchor)
            .press(
                forDuration: Self.dragPressDuration,
                thenDragTo: map.coordinate(
                    withNormalizedOffset: CGVector(
                        dx: min(max(anchor.dx + dx, 0.05), 0.95),
                        dy: min(max(anchor.dy + dy, 0.05), bandBottom / screen.height - 0.02)
                    )
                )
            )
    }

    /// The community pins that are actually on screen and clear of the sheet.
    ///
    /// `exists` is not the question: an annotation the map has scrolled off,
    /// or one behind the sheet, is in the tree and is not in the picture.
    @MainActor
    private func visibleCommunityPins(in app: XCUIApplication) -> [XCUIElement] {
        let screen = app.frame
        // A sheet that cannot be found must not silently mean "the map is a
        // zero-height strip at the top", which is what reading `.frame` off a
        // missing element gives — and which filters out every pin on screen
        // while looking exactly like a map that has none.
        let sheet = element("map-sheet", in: app)
        let sheetTop = sheet.exists && sheet.frame.height > 0
            ? sheet.frame.minY
            : screen.maxY
        return app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .allElementsBoundByIndex
            .filter { pin in
                let frame = pin.frame
                return frame.maxY < sheetTop
                    && frame.minY > screen.minY
                    && frame.minX > screen.minX
                    && frame.maxX < screen.maxX
            }
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
    private func mapElement(in app: XCUIApplication) -> XCUIElement {
        let map = app.maps.firstMatch
        XCTAssertTrue(
            map.waitForExistence(timeout: UITestTimeout.navigation),
            "the map should be on screen"
        )
        return map
    }

    /// Pinches the map by `scale` — above 1 zooms in, below 1 zooms out.
    @MainActor
    private func zoomMap(in app: XCUIApplication, by scale: CGFloat) {
        mapElement(in: app).pinch(withScale: scale, velocity: scale > 1 ? 1 : -1)
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
    /// Two gestures rather than one. The route ends up centred a fifth of the
    /// way down, and a pinch pivots on the map's centre — so zooming without
    /// panning first drives the line off the top edge. Pan the route's middle
    /// to the middle, then pinch about it.
    @MainActor
    private func expandRouteIntoTheFreedSpace(in app: XCUIApplication) {
        centrePhotoPins(in: app)
        zoomMap(in: app, by: Self.heroZoomIn)
        restoreNorth(in: app)
        // Twice more, because a pinch multiplies the line's distance from the
        // map's centre as well as its size — whatever the first pass left
        // off-centre comes back `heroZoomIn` times worse — and because a drag
        // lands short of the vector it is given, so one correction only closes
        // part of the gap. Each pass costs nothing once it is inside
        // ``centringTolerance``.
        centrePhotoPins(in: app)
        centrePhotoPins(in: app)
    }

    /// Drags the map up so the recorded line sits in the middle of the band
    /// the sheet is not over.
    ///
    /// A fixed pan, unlike every other framing gesture here, and not for want
    /// of trying: the recorded line is an `MKPolyline`, which is drawn rather
    /// than exposed, so there is no element to measure and nothing to correct
    /// against. What is known is the geometry — the recording map keeps the
    /// walker at the *window's* centre, which is behind a sheet resting at its
    /// middle detent, so the freshest end of the line is the part a reader
    /// cannot see.
    @MainActor
    private func liftRecordedLineClearOfTheSheet(in app: XCUIApplication) {
        let map = mapElement(in: app)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.34))
            .press(
                forDuration: Self.dragPressDuration,
                thenDragTo: map.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.7, dy: 0.34 - Self.recordingLift)
                )
            )
    }

    /// Drags the map up so the whole drawn line sits in the band the sheet is
    /// not over.
    ///
    /// A fixed pan for the reason ``liftRecordedLineClearOfTheSheet(in:)`` is
    /// one: the legs are `MKPolyline`s, which are drawn rather than exposed,
    /// so there is no element to measure and correct against.
    ///
    /// Safe as a *press* and drag while the maker is up, which is the part
    /// worth saying: a press of ``dragPressDuration`` is well under
    /// ``MapView/Coordinator/waypointGrabPressDuration``, so this pans the map
    /// rather than taking hold of a waypoint — and it starts clear of the line
    /// in any case, since a tap on a leg would insert a point into it.
    @MainActor
    private func liftDrawnTrailClearOfTheSheet(in app: XCUIApplication) {
        let map = mapElement(in: app)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.38))
            .press(
                forDuration: Self.dragPressDuration,
                thenDragTo: map.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.12, dy: 0.38 - Self.drawnTrailLift)
                )
            )
    }

    /// Puts the map back to north-up if a gesture has turned it.
    ///
    /// `XCUIElement.pinch` is a two-finger gesture and MapKit reads a little
    /// rotation out of it, which is not cosmetic here: turned a few degrees, a
    /// walk that is six kilometres north-to-south and under two wide draws as
    /// a diagonal that will not fit the frame at any zoom, and every attempt
    /// to pan it into place crops the other end. The give-away is MapKit's own
    /// compass, which it only shows once the map is off north — and which is
    /// also the fix, because tapping it animates back.
    @MainActor
    private func restoreNorth(in app: XCUIApplication) {
        let compass = app.buttons["Compass"]
        guard compass.waitForExistence(timeout: UITestTimeout.navigation) else { return }
        compass.tap()
        // The reset is animated, and the centring that follows measures pin
        // positions — so wait for the compass to retire rather than measure
        // the map mid-turn.
        _ = compass.waitForNonExistence(timeout: UITestTimeout.navigation)
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
    private func centrePhotoPins(in app: XCUIApplication) {
        let map = mapElement(in: app)
        guard let bounds = Self.bounds(of: photoPins(in: app)) else { return }
        let screen = app.frame
        guard screen.width > 0, screen.height > 0 else { return }

        let dx = Self.heroRouteCentreX - bounds.midX / screen.width
        let dy = Self.heroRouteCentre - bounds.midY / screen.height
        guard abs(dx) > Self.centringTolerance || abs(dy) > Self.centringTolerance else { return }

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
    private func dragSheet(in app: XCUIApplication, to target: CGFloat) {
        let grabber = app.buttons["Sheet Grabber"]
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

    @MainActor
    private func collapseSheet(in app: XCUIApplication) {
        dragSheet(in: app, to: Self.dragTarget)
        let sheet = element("map-sheet", in: app)
        let collapsed = NSPredicate { _, _ in
            sheet.frame.minY > app.frame.height * Self.collapsedSheetFraction
        }
        let settled = expectation(for: collapsed, evaluatedWith: sheet)
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: UITestTimeout.navigation),
            .completed,
            "the sheet should have come to rest at its compact detent"
        )
    }

    /// Attaches the current screen to the result bundle under `frame`'s name.
    ///
    /// Takes no application, which is the whole of why it is worth saying:
    /// `XCUIScreen.main` rather than `app.screenshot()`, because the app's own
    /// screenshot is clipped to the app's frame and loses the status bar —
    /// and that is a part of the picture App Store Connect expects to be
    /// there. The parameter this used to take was the app it then never
    /// asked.
    @MainActor
    private func capture(as frame: Frame) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = frame.rawValue
        attachment.lifetime = .keepAlways
        add(attachment)
    }}
