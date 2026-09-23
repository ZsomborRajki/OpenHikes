//
//  TrailMakerUITests.swift
//  OpenHikesUITests
//
//  Drawing a trail, from the pill on the map to a row in the library.
//
//  Nothing below this can reach it. The map is a `UIViewRepresentable` around
//  `MKMapView`, the pill is a UIKit subview positioned by a constraint the
//  sheet drives, and a press that becomes a waypoint is resolved by a gesture
//  recognizer whose state and location the touch system sets — so the one
//  question this feature exists to answer, *does pressing the map put a point
//  down*, has no unit test and cannot have one. A press opens the place sheet,
//  and whether its *Add Stop* is reachable over the map sheet is a fact about
//  presentation that only a real simulator knows.
//
//  What the suites next door cover instead: `TrailDraftTests` the arithmetic,
//  `TrailDraftLegTests` the legs and the toggle, `TrailLegRouterTests` the
//  routing over the OpenStreetMap graph, `TrailDraftRoutingTests` who is
//  asked and how often, `TrailDraftSaveTests` the row that comes out,
//  `TrailDraftControllerTests` the two pills' exclusion and the guards, and
//  `MapCoordinatorTests+TrailDraft` the map's half with a real `MKMapView` and
//  a synthesised point. Phase 3's editing adds three more —
//  `TrailDraftEditingTests` for what each operation does to the list,
//  `TrailLegMemoTests` for the shapes it restores, and
//  `MapCoordinatorTests+TrailDraftEditing` for the leg press and the drag
//  against a real map. `TrailPlaceTests` covers a place's value and its
//  ordering, `TrailDraftPlaceTests` what adding one does to the draft,
//  `TrailStopSlotTests` the open fields and where *Add Stop* puts a point,
//  `TrailStopRecentsTests` what the search remembers,
//  `MapCoordinatorTests+TrailDraftRouteChoices` the alternatives and the time
//  bubble, and `GPXPlaceRoundTripTests` the `<wpt>` either way. This is the
//  one that presses the buttons.
//

import XCTest

nonisolated final class TrailMakerUITests: XCTestCase {
    /// What the drawn trail is named, and what the library row is found by.
    private static let trailName = "Saturday Ridge"

    /// Three presses well inside the map, spread far enough apart that no two
    /// of them land on the same coordinate at any plausible zoom.
    ///
    /// Normalized rather than absolute: the map fills the window, and the
    /// window is whatever device the runner resolved. The vertical range stays
    /// in the top half, clear of the sheet at every detent it can rest at and
    /// clear of the controls on the leading edge.
    private static let drawnPoints: [CGVector] = [
        CGVector(dx: 0.45, dy: 0.20),
        CGVector(dx: 0.65, dy: 0.30),
        CGVector(dx: 0.50, dy: 0.42),
    ]

    /// The whole feature end to end: open the maker from the map, put three
    /// points down, save, and find the trail in the library.
    @MainActor
    func testDrawingATrailSavesItToTheLibrary() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(
            map.waitForExistence(timeout: UITestTimeout.navigation),
            "the map should be up before anything is drawn"
        )

        openTrailMaker(in: app)

        // Nothing is down yet: two empty fields, as Apple Maps opens its
        // directions, and a sentence saying what to do about them.
        XCTAssertTrue(
            element("trail-draft-open-start", in: app).exists
                && element("trail-draft-open-destination", in: app).exists,
            "an empty maker should open with a start and a destination to fill"
        )
        XCTAssertFalse(
            element("trail-draft-point-1", in: app).exists,
            "and neither field is filled in for the hiker"
        )
        XCTAssertTrue(
            element("trail-draft-empty", in: app).exists,
            "an empty maker should say how to start"
        )
        let save = element("trail-draft-save", in: app)
        XCTAssertFalse(
            save.isEnabled,
            "a trail with no points cannot be saved"
        )

        drawTrailPoints(Self.drawnPoints, on: map, in: app)

        // Three points, in the order they went down, with the running length
        // on the header beside them.
        XCTAssertTrue(
            element("trail-draft-point-3", in: app).exists,
            "the third point should be listed"
        )
        XCTAssertTrue(
            element("trail-draft-length", in: app).exists,
            "the maker should show how long the line is so far"
        )
        XCTAssertTrue(save.isEnabled, "three points is a trail")

        // Named on the way out, in the alert Save opens — the same shape a
        // stopped recording is named in, and the only place the maker asks.
        save.tap()
        nameTheTrail(Self.trailName, in: app)

        // A saved trail lands exactly where a stopped recording lands: on its
        // own screen, over a map drawing it.
        XCTAssertTrue(
            app.navigationBars[Self.trailName].waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "saving should open the trail it just made"
        )

        // And it is in the library, which is the claim that matters: a drawn
        // trail is an ordinary hike from here on, reachable the way every
        // other hike is.
        popScreen(in: app)
        awaitHikeRow(titled: Self.trailName, in: app)
    }

    /// The ✕ is the explicit destructive way out, so it asks what becomes
    /// of the drawing, and *Discard Trail* throws it away.
    @MainActor
    func testClosingCanDiscardTheDrawing() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Array(Self.drawnPoints.prefix(2)), on: map, in: app)

        closeTrailMaker(choosing: "Discard Trail", in: app)

        // And nothing was kept: reopening the maker starts from nothing.
        openTrailMaker(in: app)
        XCTAssertTrue(
            element("trail-draft-empty", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "a discarded drawing should not come back"
        )
    }

    /// Back is the quiet way out: it keeps the drawing without asking, and the
    /// next visit picks it up where it was left.
    @MainActor
    func testBackKeepsTheDrawingForLaterWithoutConfirmation() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Array(Self.drawnPoints.prefix(2)), on: map, in: app)
        popScreen(in: app)
        XCTAssertFalse(
            app.buttons["Discard Trail"].exists,
            "back should keep the drawing without opening the close dialog"
        )
        XCTAssertTrue(
            waitUntil { element("map-sheet", in: app).exists },
            "back should return immediately to the map"
        )

        openTrailMaker(in: app)
        XCTAssertTrue(
            element("trail-draft-point-2", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "a drawing kept for later should be there the next time"
        )
    }

    /// The pill takes the slot the camera pill is in, and the two are offered
    /// on opposite signals — so the search screen has one and a hike's screen
    /// has the other, never both.
    @MainActor
    func testTheMakerAndCameraPillsTakeTurns() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        let maker = element("map-trail-maker-button", in: app)
        let camera = element("map-camera-button", in: app)

        XCTAssertTrue(
            maker.waitForExistence(timeout: UITestTimeout.existence),
            "the search screen offers the maker"
        )
        XCTAssertFalse(camera.exists, "and not the camera, which has nothing to file into")

        // A hike's own screen is the camera's half of the arrangement.
        openHikeDetail(in: app)
        XCTAssertTrue(
            camera.waitForExistence(timeout: UITestTimeout.existence),
            "a pushed hike offers the camera"
        )
        // Waited on rather than asserted outright: the pill leaves on a fade,
        // and it is still in the hierarchy for the quarter-second that takes.
        XCTAssertTrue(
            waitUntil { !maker.exists },
            "the maker should give up the slot it shares with the camera"
        )

        popScreen(in: app)
        XCTAssertTrue(
            waitUntil { maker.exists && !camera.exists },
            "backing out should hand the slot back"
        )
    }

    /// The switch that makes legs follow mapped paths, and the one thing it
    /// is gated on.
    ///
    /// **What this covers that nothing below it can**: the trail graph
    /// reaching the maker at all. The router is handed to
    /// ``TrailDraftController`` by `OpenHikesModel+Composition.swift`, and
    /// whether that wiring happened is invisible to every unit test — the
    /// maker builds and draws perfectly well with no router, which is exactly
    /// the bug this would otherwise ship. The switch is offered when there is
    /// a graph to ask and withheld when there is not, so its presence is the
    /// wiring made visible.
    ///
    /// The routing itself is asserted next door in `TrailLegRouterTests`,
    /// against graphs built in code: which path a leg follows is arithmetic
    /// over coordinates, and driving it through a simulator would be a slower
    /// way of asking a worse question — where the camera happens to be
    /// pointing.
    @MainActor
    func testTheSwitchIsOfferedOnlyWhenThereIsAGraphToAsk() {
        let withoutGraph = launchApp()
        openTrailMaker(in: withoutGraph)
        XCTAssertFalse(
            element("trail-draft-snap", in: withoutGraph).exists,
            "a launch that cannot ask OpenStreetMap should not offer to"
        )
        withoutGraph.terminate()

        let app = launchApp(
            arguments: ["--ui-test-trail-graph=\(UITestFixture.trailGraphName)"]
        )
        openTrailMaker(in: app)
        XCTAssertTrue(
            element("trail-draft-snap", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "a launch with a trail graph should offer to follow paths"
        )
    }

    /// Turning it off keeps the drawing, which is the half of *re-resolve,
    /// don't discard* a hiker would notice: a switch that threw away the
    /// points would be one nobody could risk touching.
    @MainActor
    func testTurningPathFollowingOffKeepsTheDrawing() {
        let app = launchApp(
            arguments: ["--ui-test-trail-graph=\(UITestFixture.trailGraphName)"]
        )
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)

        let snap = element("trail-draft-snap", in: app)
        XCTAssertTrue(
            scrollIntoView(snap, in: app),
            "the Follow Paths switch should remain reachable below the stops"
        )
        snap.tap()

        XCTAssertTrue(
            element("trail-draft-point-3", in: app).exists,
            "straightening the line should not take the points away"
        )
        XCTAssertTrue(
            element("trail-draft-save", in: app).isEnabled,
            "a straightened trail is still a trail"
        )
    }

    // MARK: - Helpers

    /// Presses the ✕ and answers the question it asks about the drawing.
    @MainActor
    private func closeTrailMaker(choosing answer: String, in app: XCUIApplication) {
        element("trail-draft-close", in: app).tap()
        let button = app.buttons[answer]
        XCTAssertTrue(
            button.waitForExistence(timeout: UITestTimeout.navigation),
            "closing a drawing should ask what becomes of it"
        )
        button.tap()
        XCTAssertTrue(
            waitUntil { element("map-sheet", in: app).exists },
            "\(answer) should land back on the map"
        )
    }

    /// Answers the alert Save opens, which is the only place the maker asks
    /// what the trail is called.
    ///
    /// The field opens blank — the placeholder is the default name — so this
    /// types rather than replaces, unlike `stopRecording(named:in:)` next
    /// door.
    @MainActor
    private func nameTheTrail(_ name: String, in app: XCUIApplication) {
        let prompt = app.alerts["Name Your Trail"]
        XCTAssertTrue(
            prompt.waitForExistence(timeout: UITestTimeout.navigation),
            "saving should ask what the trail is called"
        )
        let field = prompt.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UITestTimeout.navigation))
        // Typed into the field the alert focused on the way in, rather than
        // tapped first: a tap on a field that already has the keyboard opens
        // the edit menu over it — AutoFill, Paste.
        field.typeText(name)
        // **The alert can move under the press.** On a freshly created
        // simulator the software keyboard hides while a name is typed and
        // comes back a moment later, carrying the alert up with it, and a
        // press aimed at where Save was lands on the dimmed screen behind it —
        // the alert stays up with the name typed in, and the save never
        // happens. Seen in a screen recording of exactly that. Pressed again
        // only if it happened: a press that landed has taken the alert down.
        let save = prompt.buttons["Save"]
        save.tap()
        if !waitUntil(timeout: UITestTimeout.existence, { !prompt.exists }) {
            save.tap()
        }
    }
}

// MARK: - Editing what is already drawn

/// The Phase 3 gestures, which are the ones a suite below this cannot reach at
/// all.
///
/// Every operation's arithmetic is asserted next door, in
/// `TrailDraftEditingTests` for what each does to the list, and none of that
/// says whether a hiker can *get* to any of it. A swipe action, a direct
/// drag and a press that lands on a line are three things only a real
/// simulator does, and the first two were wrong the first time on the hikes
/// list. This is where they are pressed.
extension TrailMakerUITests {
    /// Taking a stop out.
    ///
    /// Through the platform's trailing swipe action. The list rests outside
    /// edit mode, so no delete circle occupies the leading edge.
    @MainActor
    func testRemovingAStop() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)

        let third = element("trail-draft-point-3", in: app)
        XCTAssertFalse(app.buttons["Delete"].exists, "no leading delete control should be visible")
        element("trail-draft-point-2", in: app).swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: UITestTimeout.existence),
            "swiping a stop should reveal the standard delete action"
        )
        delete.tap()
        XCTAssertTrue(
            waitUntil { !third.exists },
            "deleting should leave two points"
        )
        XCTAssertTrue(
            element("trail-draft-point-2", in: app).label.contains("Destination"),
            "the stop after the deleted one should close the gap"
        )
    }

    /// *Add Stop* on a pin dropped on a leg puts the point **into** it, which
    /// cannot be told apart from an append without a real map.
    @MainActor
    func testPressingALegAddsAPointInTheMiddle() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        let ends = Array(Self.drawnPoints.prefix(2))
        drawTrailPoints(ends, on: map, in: app)
        let length = element("trail-draft-length", in: app).label

        // A third of the way along the straight leg between the two presses —
        // not halfway, where the route's time bubble sits and takes the press.
        let onTheLeg = CGVector(
            dx: ends[0].dx + (ends[1].dx - ends[0].dx) / 3,
            dy: ends[0].dy + (ends[1].dy - ends[0].dy) / 3
        )
        dropPin(at: onTheLeg, on: map)
        tapInPlaceSheet("trail-place-add-stop", in: app)

        let third = element("trail-draft-point-3", in: app)
        XCTAssertTrue(
            third.waitForExistence(timeout: UITestTimeout.navigation),
            "Add Stop should put a third point down"
        )
        // **It went in at row two, which is the whole of what *into* means.**
        // An append would leave row two sitting at the trail's old length; an
        // insert moves it somewhere short of it. The rows print only a title,
        // so the distance is read from their accessibility value.
        XCTAssertFalse(
            (element("trail-draft-point-2", in: app).value as? String ?? "").contains(length),
            "a point appended to the end would have left row two at \(length)"
        )
        XCTAssertTrue(
            (third.value as? String ?? "").contains(element("trail-draft-length", in: app).label),
            "the last row should sit at the trail's full length"
        )
    }

    /// Reordering directly, without an Edit/Done mode to enter first.
    ///
    /// The drag still has to be slow and held, because a reorder commits on the
    /// *drop*. That was paid for once on `HikeOrderUITests` and is not
    /// rediscovered here.
    @MainActor
    func testReorderingThePoints() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)
        let length = element("trail-draft-length", in: app).label

        let second = element("trail-draft-point-2", in: app)
        XCTAssertFalse(app.navigationBars.buttons["Edit"].exists)

        // A press and hold on the row itself lifts it — there is no grabber.
        // Slow and held at both ends, as in `HikeOrderUITests`: a reorder
        // commits on the drop, and a quick flick is over before the list has
        // decided it was a drag.
        element("trail-draft-point-3", in: app)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1.2,
            thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
            withVelocity: .slow,
            thenHoldForDuration: 0.8
        )

        // The line is a different line now, which is the whole point of the
        // operation: the same three places walked in another order are a
        // different length.
        XCTAssertTrue(
            waitUntil { element("trail-draft-length", in: app).label != length },
            "reordering the points should change the trail they describe"
        )

        // The explicit close and save controls remain available because there
        // is no editing mode to take over the toolbar.
        XCTAssertTrue(
            element("trail-draft-close", in: app).exists,
            "the ✕ stays put while rows are being dragged"
        )
        XCTAssertFalse(app.navigationBars.buttons["Done"].exists)
        XCTAssertTrue(
            element("trail-draft-save", in: app).isEnabled,
            "a reordered trail is still a trail"
        )
    }
}

// MARK: - The route list, and the search behind it

/// The Apple Maps arrangement: a start, its stops and its destination, each row
/// a field that opens a search, with *Add Stop* pinned under them.
///
/// Only a simulator can answer whether a place picked in the sheet lands in
/// the row the sheet was opened from. `TrailDraftTests` covers what the draft
/// does with a name once it has one; this presentation path is not reachable
/// from there.
extension TrailMakerUITests {
    /// The two empty fields each open the search on themselves, and *Add Stop*
    /// waits until both are filled.
    @MainActor
    func testTheOpenFieldsOpenTheSearch() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        XCTAssertFalse(
            element("trail-draft-add-stop", in: app).exists,
            "the open fields are the way in, and Add Stop would be a second answer to one question"
        )

        element("trail-draft-open-destination", in: app).tap()
        XCTAssertTrue(
            element("trail-stop-search-field", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "an open field should open the search sheet"
        )
        XCTAssertTrue(
            app.navigationBars["Destination"].exists,
            "the sheet should say which field it was opened from"
        )
        // Offered with no fix and no recents at all, which is this launch: the
        // row waits for a position rather than being missing until one comes.
        XCTAssertTrue(
            element("trail-stop-search-here", in: app).exists,
            "My Location should head the list before anything is typed"
        )
        element("trail-stop-search-cancel", in: app).tap()
        XCTAssertTrue(
            waitUntil { !element("trail-stop-search-field", in: app).exists },
            "cancelling should put the search away"
        )

        drawTrailPoints(Array(Self.drawnPoints.prefix(2)), on: map, in: app)
        let add = element("trail-draft-add-stop", in: app)
        XCTAssertTrue(
            add.waitForExistence(timeout: UITestTimeout.navigation),
            "a route with both ends should offer to add a stop"
        )
        add.tap()
        XCTAssertTrue(
            element("trail-stop-search-field", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "Add Stop should open the search sheet"
        )
        element("trail-stop-search-cancel", in: app).tap()
    }

    /// A stop remains a tappable search field while it also carries the direct
    /// drag and trailing swipe gestures.
    @MainActor
    func testTappingAStopOpensTheSearchOnThatRow() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)

        // The middle of three, so the sheet has a role to name that is neither
        // of the two ends — which is what says it opened on *this* row.
        element("trail-draft-point-2", in: app).tap()

        XCTAssertTrue(
            element("trail-stop-search-field", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "a stop row should open the search alongside its editing gestures"
        )
        XCTAssertTrue(
            app.navigationBars["Stop 1"].exists,
            "the sheet should say which row it was opened from"
        )
        element("trail-stop-search-cancel", in: app).tap()

        // And the drawing is untouched: opening a search places nothing.
        XCTAssertTrue(
            waitUntil { element("trail-draft-point-3", in: app).exists },
            "cancelling the search should leave the route as it was"
        )
    }

    /// Every row says what it is to the route, and the words are the ones a
    /// hiker reads rather than a number.
    ///
    /// Under automation nothing reverse-geocodes — `makeTrailStopNaming()` is
    /// `nil` when tests are running — so these are exactly the fallbacks, which
    /// is what makes them assertable at all.
    @MainActor
    func testTheRouteReadsAsStartStopsAndDestination() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)

        XCTAssertTrue(
            element("trail-draft-point-1", in: app).label.contains("Start"),
            "the first row is where the route starts"
        )
        XCTAssertTrue(
            element("trail-draft-point-2", in: app).label.contains("Stop 1"),
            "the middle row is a stop, counted from one"
        )
        XCTAssertTrue(
            element("trail-draft-point-3", in: app).label.contains("Destination"),
            "the last row is where the route ends"
        )
    }
}

// MARK: - The place sheet

/// What a press on the map opens: Apple Maps' place card, and the one way a
/// point goes down from the map.
///
/// What the sheet does to the draft is asserted next door —
/// `TrailStopSlotTests` for where *Add Stop* puts a point,
/// `TrailDraftPlaceTests` for removing a place, and
/// `MapCoordinatorTests+TrailDraft` for the pin a press drops and the
/// selection a tap raises. None of that says whether the sheet comes up over
/// the map's own sheet and can be used there.
extension TrailMakerUITests {
    /// A dropped pin's card says where it is. Closing the card leaves the pin
    /// standing, as Apple Maps does, and a tap on the pin opens the card
    /// again; *Remove Pin* is what takes it away, and it puts nothing on the
    /// trail.
    @MainActor
    func testTheDroppedPinStaysUntilItIsRemoved() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        dropPin(at: Self.drawnPoints[0], on: map)

        let sheet = element("trail-place-sheet", in: app)
        XCTAssertTrue(
            sheet.waitForExistence(timeout: UITestTimeout.navigation),
            "a press on the map should open the place sheet"
        )
        XCTAssertEqual(element("trail-place-title", in: app).label, "Dropped Pin")
        XCTAssertTrue(
            element("trail-place-coordinates", in: app).exists,
            "the sheet should say where the pin is"
        )
        XCTAssertTrue(element("trail-place-share", in: app).exists, "and offer to share it")

        tapInPlaceSheet("trail-place-close", in: app)
        let pin = element("trail-draft-dropped-pin", in: app)
        XCTAssertTrue(
            pin.waitForExistence(timeout: UITestTimeout.navigation),
            "closing the card should leave the pin on the map"
        )
        pin.tap()
        XCTAssertTrue(
            sheet.waitForExistence(timeout: UITestTimeout.navigation),
            "a tap on the pin should open its card again"
        )

        tapInPlaceSheet("trail-place-remove", in: app)

        XCTAssertTrue(
            waitUntil { !pin.exists },
            "Remove Pin should take the pin off the map"
        )
        XCTAssertFalse(
            element("trail-draft-point-1", in: app).exists,
            "removing the pin should put nothing on the trail"
        )
        XCTAssertTrue(
            element("trail-draft-open-start", in: app).exists,
            "and the start field should still be open"
        )
    }
}
