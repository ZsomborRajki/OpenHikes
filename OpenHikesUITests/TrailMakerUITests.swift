//
//  TrailMakerUITests.swift
//  OpenHikesUITests
//
//  Drawing a trail, from the pill on the map to a row in the library.
//
//  Nothing below this can reach it. The map is a `UIViewRepresentable` around
//  `MKMapView`, the pill is a UIKit subview positioned by a constraint the
//  sheet drives, and a tap that becomes a waypoint is resolved by a gesture
//  recognizer whose state and location the touch system sets — so the one
//  question this feature exists to answer, *does tapping the map put a point
//  down*, has no unit test and cannot have one. Since Phase 4 that question
//  has a second half: a tap opens a callout, and whether its buttons can be
//  *reached* is a fact about MapKit's own view hierarchy that only a real
//  simulator knows.
//
//  What the suites next door cover instead: `TrailDraftTests` the arithmetic,
//  `TrailDraftLegTests` the legs and the toggle, `TrailLegRouterTests` the
//  routing over the OpenStreetMap graph, `TrailDraftRoutingTests` who is
//  asked and how often, `TrailDraftSaveTests` the row that comes out,
//  `TrailDraftControllerTests` the two pills' exclusion and the guards, and
//  `MapCoordinatorTests+TrailDraft` the map's half with a real `MKMapView` and
//  a synthesised point. Phase 3's editing adds four more — `TrailDraftEditingTests`
//  for what each operation does to the list, `TrailDraftHistoryTests` for undo,
//  `TrailLegMemoTests` for the shapes it restores, and
//  `MapCoordinatorTests+TrailDraftEditing` for the leg tap and the drag against
//  a real map. Phase 4 adds `TrailPlaceTests` for the value and its ordering,
//  `TrailDraftPlaceTests` for what marking one does to the draft,
//  `TrailDraftPinActionTests` for which verbs a callout offers, and
//  `GPXPlaceRoundTripTests` for the `<wpt>` either way. This is the one that
//  presses the buttons.
//

import XCTest

nonisolated final class TrailMakerUITests: XCTestCase {
    /// What the drawn trail is named, and what the library row is found by.
    private static let trailName = "Saturday Ridge"

    /// Three taps well inside the map, spread far enough apart that no two of
    /// them land on the same coordinate at any plausible zoom.
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

    /// Three taps whose two legs are very different lengths, so how far the
    /// middle point sits along the line is a different number each way round —
    /// which is the only thing on screen a reversal changes. Evenly spaced
    /// points would reverse into the same three figures and prove nothing.
    private static let lopsidedPoints: [CGVector] = [
        CGVector(dx: 0.30, dy: 0.18),
        CGVector(dx: 0.34, dy: 0.22),
        CGVector(dx: 0.85, dy: 0.42),
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

        // Nothing is down yet, and the screen says what to do about it.
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

    /// Cancel throws the drawing away and says so first. The confirmation is
    /// what makes the button safe to put next to Save.
    @MainActor
    func testCancellingDiscardsTheDrawing() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Array(Self.drawnPoints.prefix(2)), on: map, in: app)

        element("trail-draft-cancel", in: app).tap()
        let discard = app.buttons["Discard"]
        XCTAssertTrue(
            discard.waitForExistence(timeout: UITestTimeout.navigation),
            "cancelling a drawing should ask before throwing it away"
        )
        discard.tap()

        XCTAssertTrue(
            waitUntil { element("map-sheet", in: app).exists },
            "cancelling should land back on the map"
        )

        // And nothing was kept: reopening the maker starts from nothing.
        openTrailMaker(in: app)
        XCTAssertTrue(
            element("trail-draft-empty", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "a discarded drawing should not come back"
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
        XCTAssertTrue(snap.waitForExistence(timeout: UITestTimeout.navigation))
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
        field.tap()
        field.typeText(name)
        prompt.buttons["Save"].tap()
    }

}

// MARK: - Editing what is already drawn

/// The Phase 3 gestures, which are the ones a suite below this cannot reach at
/// all.
///
/// Every operation's arithmetic is asserted next door — `TrailDraftEditingTests`
/// for what each does to the list, `TrailDraftHistoryTests` for undo — and none
/// of that says whether a hiker can *get* to any of it. A swipe, a context
/// menu, an edit-mode drag and a tap that lands on a line are four things only
/// a real simulator does, and three of them were wrong the first time on the
/// hikes list. This is where they are pressed.
extension TrailMakerUITests {
    /// Taking a stop out, and putting it back.
    ///
    /// The pair rather than either alone: delete is the destructive half of
    /// this screen and undo is what makes it safe, so a suite that covered only
    /// the first would be green on a build where the second never appeared.
    ///
    /// **Through the red circle rather than a swipe**, and that is the cost of
    /// the rows carrying their grabbers permanently: a `List` in edit mode
    /// offers its delete on the leading edge and does not answer a swipe at
    /// all. The same pairing Apple Maps' own directions rows have — a handle
    /// trailing, a minus leading — and the swipe that used to do this is gone
    /// with the mode it belonged to.
    @MainActor
    func testRemovingAStopAndUndoingIt() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)

        let third = element("trail-draft-point-3", in: app)
        // The circle sits inside the row's leading edge, before the route's own
        // dot. A coordinate rather than a query, because it is the `List`'s own
        // view and carries no identifier this app could give it.
        element("trail-draft-point-2", in: app)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5))
            .tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: UITestTimeout.existence),
            "the delete circle on a stop should offer to remove it"
        )
        delete.tap()
        XCTAssertTrue(
            waitUntil { !third.exists },
            "deleting should leave two points"
        )

        chooseAction("Undo", in: app)

        XCTAssertTrue(
            third.waitForExistence(timeout: UITestTimeout.navigation),
            "undo should bring the deleted point back"
        )
    }

    /// A tap on a leg puts a point **into** it, which is the half of the
    /// canvas that cannot be told apart from an append without a real map: both
    /// are one tap, and which one happens is decided by whether a line was
    /// under the thumb.
    @MainActor
    func testTappingALegAddsAPointInTheMiddle() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        let ends = Array(Self.drawnPoints.prefix(2))
        drawTrailPoints(ends, on: map, in: app)
        let length = element("trail-draft-length", in: app).label

        // Halfway between the two taps, which on a launch with no trail graph
        // is exactly where the straight leg between them is drawn.
        let middle = CGVector(
            dx: (ends[0].dx + ends[1].dx) / 2,
            dy: (ends[0].dy + ends[1].dy) / 2
        )
        map.coordinate(withNormalizedOffset: middle).tap()
        // *Add Stop* rather than *Make Destination*: the pin remembers the leg
        // the thumb landed on, and this is the verb that uses it.
        confirmDroppedPin("trail-draft-pin-add-stop", in: app)

        let third = element("trail-draft-point-3", in: app)
        XCTAssertTrue(
            third.waitForExistence(timeout: UITestTimeout.navigation),
            "the leg's callout should put a third point down"
        )
        // **It went in at row two, which is the whole of what *into* means.**
        //
        // Not "the trail did not get longer", which is what this asserted
        // through Phase 3 and is no longer safe: selecting a callout lets
        // MapKit scroll the map to make room for it, so the screen point
        // halfway between two taps is no longer exactly on the line by the
        // time the third tap lands, and an inserted point a little off the
        // line lengthens the trail exactly as an appended one would. What
        // still tells the two apart is *where the new point landed in the
        // list*: an append leaves row two sitting at the trail's old length,
        // and an insert moves it somewhere short of it.
        XCTAssertFalse(
            element("trail-draft-point-2", in: app).label.contains(length),
            "a point appended to the end would have left row two at \(length)"
        )
        XCTAssertTrue(
            third.label.contains(element("trail-draft-length", in: app).label),
            "the last row should sit at the trail's full length"
        )
    }

    /// Reordering, which no longer has to be asked for.
    ///
    /// **The whole point of the test is that nothing precedes the drag.** Phase
    /// 6 reached this through a context menu on a row and an edit mode with a
    /// Done control; the maker's list is Apple Maps' directions list now and is
    /// in edit mode from the moment it appears, so the grabber is on every row
    /// and the first gesture is the move itself.
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

        let third = element("trail-draft-point-3", in: app)
        let second = element("trail-draft-point-2", in: app)

        // The trailing edge is where the grabber is; slow, and held at the
        // end, because the move is committed on the drop.
        third.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).press(
            forDuration: 0.8,
            thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.0)),
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

        // And the edit menu was never taken away, because there is no mode to
        // be in — the Done control that used to replace it is gone.
        XCTAssertTrue(
            element("trail-draft-actions", in: app).exists,
            "the edit menu stays put while rows are being dragged"
        )
        XCTAssertTrue(
            element("trail-draft-save", in: app).isEnabled,
            "a reordered trail is still a trail"
        )
    }

    /// The two shape verbs, which have no gesture and exist only in the menu.
    @MainActor
    func testReversingAndClosingTheLoop() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.lopsidedPoints, on: map, in: app)
        let second = element("trail-draft-point-2", in: app).label

        chooseAction("Reverse", in: app)

        // Same three places, same total length, walked the other way — so what
        // changes is how far along the middle one sits.
        XCTAssertTrue(
            waitUntil { element("trail-draft-point-2", in: app).label != second },
            "reversing should walk the line the other way"
        )

        chooseAction("Close the Loop", in: app)

        XCTAssertTrue(
            element("trail-draft-point-4", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "closing the loop should bring the line back to where it started"
        )
    }

    /// *Clear* is the one edit that asks first, and the question is what makes
    /// it safe to put in a menu beside Undo.
    @MainActor
    func testClearingAsksFirstAndCanBeUndone() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)

        chooseAction("Clear", in: app)
        let confirm = app.buttons["Clear"]
        XCTAssertTrue(
            confirm.waitForExistence(timeout: UITestTimeout.existence),
            "clearing should ask before removing the points"
        )
        confirm.tap()

        XCTAssertTrue(
            element("trail-draft-empty", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "clearing should leave an empty maker"
        )

        chooseAction("Undo", in: app)

        XCTAssertTrue(
            element("trail-draft-point-3", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "the drawing should come back, because clearing is an edit like any other"
        )
    }

    /// Opens the edit menu and takes one of the things in it.
    ///
    /// By title rather than by identifier, and that is a finding rather than a
    /// preference: a `Menu`'s contents are rebuilt by the system when it opens,
    /// and the `accessibilityIdentifier` on a button inside one does not come
    /// through — the first version of these tests looked for them and found
    /// nothing. The context menu on a row behaves the same way, which is why
    /// `testReorderingThePoints` asks for *Reorder Points* by name too.
    @MainActor
    private func chooseAction(_ title: String, in app: XCUIApplication) {
        let menu = element("trail-draft-actions", in: app)
        XCTAssertTrue(
            menu.waitForExistence(timeout: UITestTimeout.existence),
            "the maker should offer its edit menu"
        )
        menu.tap()
        let action = app.buttons[title]
        XCTAssertTrue(
            action.waitForExistence(timeout: UITestTimeout.existence),
            "\(title) should be in the edit menu"
        )
        action.tap()
    }
}

// MARK: - The route list, and the search behind it

/// The Apple Maps arrangement: a start, its stops and its destination, each row
/// a field that opens a search, with *Add Stop* pinned under them.
///
/// Only a simulator can answer the two questions here. **Does a row still
/// answer a tap while the list is permanently in edit mode** — which is the one
/// thing the redesign rests on, and which the hikes list's own finding says is
/// false for a `NavigationLink` — and does a place picked in the sheet land in
/// the row the sheet was opened from. `TrailDraftTests` covers what the draft
/// does with a name once it has one; neither of these is reachable from there.
extension TrailMakerUITests {
    /// *Add Stop* opens the search, and it is there before anything is drawn.
    @MainActor
    func testAddStopOpensTheSearch() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)

        // Present over an empty draft, which is the half that makes the section
        // read as a route being built rather than as a list of what is there.
        let add = element("trail-draft-add-stop", in: app)
        XCTAssertTrue(
            add.waitForExistence(timeout: UITestTimeout.navigation),
            "an empty maker should still offer to add a stop"
        )
        add.tap()

        XCTAssertTrue(
            element("trail-stop-search-field", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "Add Stop should open the search sheet"
        )
        element("trail-stop-search-cancel", in: app).tap()
        XCTAssertTrue(
            waitUntil { !element("trail-stop-search-field", in: app).exists },
            "cancelling should put the search away"
        )
    }

    /// A stop row answers a tap, with the list in edit mode the whole time.
    ///
    /// **This is the assertion the redesign stands on.** A `List` gives a row's
    /// tap to the list once edit mode is on — that is what the hikes list found
    /// for its `NavigationLink` rows, and it is why reordering used to be a mode
    /// with a way out. These rows are `Button`s and are tapped while the
    /// grabbers are showing; if that ever stops working, this goes red here
    /// rather than in a hiker's hands.
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
            "a stop row should open the search even with the list in edit mode"
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

// MARK: - Marking places

/// The other half of Phase 4, and the half that cannot be reached without a
/// simulator: a callout button opens a sheet, and the sheet writes back when
/// it is dismissed.
///
/// Everything about *what* a place is is asserted next door — `TrailPlaceTests`
/// for the value and its ordering, `TrailDraftPlaceTests` for what marking one
/// does to the draft, `GPXPlaceRoundTripTests` for the `<wpt>` either way, and
/// `MapCoordinatorTests+TrailPlaces` for the pins against a real map. None of
/// that says whether a hiker can get from a tap on the map to a named spring.
extension TrailMakerUITests {
    /// Marking a place from the list, which is the half a tap on the map does
    /// not reach.
    ///
    /// **This exists because the controls here were a `Menu` and stopped
    /// working.** A `Menu` inside a `List` does not open once the list is in
    /// edit mode, which the route's grabbers now require permanently — so the
    /// three entries are ordinary `Button` rows, and nothing on the screen
    /// would have said they were broken. `testMarkingAPlaceFromTheMap` next
    /// door goes through the map's callout instead and was green the whole
    /// time it was.
    @MainActor
    func testMarkingAPlaceFromTheList() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)

        let centre = element("trail-draft-add-place", in: app)
        XCTAssertTrue(
            centre.waitForExistence(timeout: UITestTimeout.navigation),
            "the places list should offer to mark the map's centre"
        )
        centre.tap()

        XCTAssertTrue(
            element("trail-place-name", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "marking a place from the list should open the editor on it"
        )
        element("trail-place-done", in: app).tap()

        XCTAssertTrue(
            waitUntil { !element("trail-draft-places-empty", in: app).exists },
            "and the place should be listed"
        )
    }

    /// The whole place flow: tap the map, mark a place, name it, and find it
    /// listed under the points with the symbol it was given.
    @MainActor
    func testMarkingAPlaceFromTheMap() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)

        // Nothing marked yet, and the screen says both ways to start.
        XCTAssertTrue(
            element("trail-draft-places-empty", in: app).exists,
            "an empty maker should say how to mark a place"
        )

        map.coordinate(withNormalizedOffset: Self.drawnPoints[0]).tap()
        confirmDroppedPin("trail-draft-pin-mark-a-place", in: app)

        // Marking and naming are one gesture: the editor comes up on the place
        // that was just put down.
        let name = element("trail-place-name", in: app)
        XCTAssertTrue(
            name.waitForExistence(timeout: UITestTimeout.navigation),
            "marking a place should open the editor on it"
        )
        name.tap()
        name.typeText("Kühroint")
        element("trail-place-symbol-\(TrailPlaceSymbolIdentifier.shelter)", in: app).tap()
        element("trail-place-done", in: app).tap()

        // Written back on the way out, and listed under the points.
        XCTAssertTrue(
            waitUntil { app.staticTexts["Kühroint"].exists },
            "the named place should be listed"
        )
        XCTAssertFalse(
            element("trail-draft-places-empty", in: app).exists,
            "a marked place should replace the empty caption"
        )
        // And the line is untouched: a place is a spot beside a trail rather
        // than a point of one.
        XCTAssertFalse(
            element("trail-draft-point-1", in: app).exists,
            "marking a place should not put a waypoint down"
        )
    }

    /// Removing is the destructive half, and the editor is one of the two
    /// places it is offered from — the other is the pin's own callout, which
    /// needs a press on a marker MapKit has drawn.
    @MainActor
    func testRemovingAPlaceFromTheEditor() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        map.coordinate(withNormalizedOffset: Self.drawnPoints[0]).tap()
        confirmDroppedPin("trail-draft-pin-mark-a-place", in: app)
        let name = element("trail-place-name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: UITestTimeout.navigation))
        name.tap()
        name.typeText("Spring")
        element("trail-place-done", in: app).tap()
        XCTAssertTrue(waitUntil { app.staticTexts["Spring"].exists })

        // Back into the editor from the row, and out through Remove.
        app.staticTexts["Spring"].tap()
        let delete = element("trail-place-delete", in: app)
        XCTAssertTrue(
            delete.waitForExistence(timeout: UITestTimeout.navigation),
            "the editor should offer to remove the place"
        )
        delete.tap()

        XCTAssertTrue(
            element("trail-draft-places-empty", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "removing the last place should bring the empty caption back"
        )
    }
}

/// The raw values the symbol picker's identifiers are spelled from.
///
/// Written out rather than read off `TrailPlaceSymbol`, which is in the app
/// target and not visible here. Spelling them again is what makes a rename of
/// one of those raw values fail this suite — which it should, because the raw
/// value is also the stored id and the GPX `<sym>`.
private enum TrailPlaceSymbolIdentifier {
    static let shelter = "Shelter"
}
