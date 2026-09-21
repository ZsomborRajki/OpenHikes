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
//  down*, has no unit test and cannot have one.
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
//  a real map. This is the one that presses the buttons.
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

        openTheMaker(in: app)

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

        draw(Self.drawnPoints, on: map, in: app)

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

        openTheMaker(in: app)
        draw(Array(Self.drawnPoints.prefix(2)), on: map, in: app)

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
        openTheMaker(in: app)
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
        openTheMaker(in: withoutGraph)
        XCTAssertFalse(
            element("trail-draft-snap", in: withoutGraph).exists,
            "a launch that cannot ask OpenStreetMap should not offer to"
        )
        withoutGraph.terminate()

        let app = launchApp(
            arguments: ["--ui-test-trail-graph=\(UITestFixture.trailGraphName)"]
        )
        openTheMaker(in: app)
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

        openTheMaker(in: app)
        draw(Self.drawnPoints, on: map, in: app)

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

    /// Opens the maker from the map's own pill, which is the only way in.
    @MainActor
    private func openTheMaker(in app: XCUIApplication) {
        let pill = element("map-trail-maker-button", in: app)
        XCTAssertTrue(
            pill.waitForExistence(timeout: UITestTimeout.existence),
            "the search screen should offer to make a trail"
        )
        pill.tap()
        XCTAssertTrue(
            element("trail-draft-save", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "tapping the pill should open the maker"
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
        field.tap()
        field.typeText(name)
        prompt.buttons["Save"].tap()
    }

    /// Taps the map at each offset and waits for the point to be listed.
    ///
    /// Waiting on the row rather than tapping three times and asserting once:
    /// a tap that missed is indistinguishable from one the app has not
    /// processed yet, and only the wait tells them apart. No fixed sleep —
    /// each point is its own effect to wait on.
    @MainActor
    private func draw(_ offsets: [CGVector], on map: XCUIElement, in app: XCUIApplication) {
        for (index, offset) in offsets.enumerated() {
            map.coordinate(withNormalizedOffset: offset).tap()
            let row = element("trail-draft-point-\(index + 1)", in: app)
            XCTAssertTrue(
                row.waitForExistence(timeout: UITestTimeout.navigation),
                "tapping the map should put point \(index + 1) down"
            )
        }
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
    /// A swipe takes a point out, and the menu puts it back.
    ///
    /// The pair rather than either alone: delete is the destructive half of
    /// this phase and undo is what makes it safe, so a suite that covered only
    /// the first would be green on a build where the second never appeared.
    @MainActor
    func testSwipingAPointAwayAndUndoingIt() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTheMaker(in: app)
        draw(Self.drawnPoints, on: map, in: app)

        let third = element("trail-draft-point-3", in: app)
        element("trail-draft-point-2", in: app).swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: UITestTimeout.existence),
            "a swipe on a point should offer to delete it"
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

        openTheMaker(in: app)
        let ends = Array(Self.drawnPoints.prefix(2))
        draw(ends, on: map, in: app)
        let length = element("trail-draft-length", in: app).label

        // Halfway between the two taps, which on a launch with no trail graph
        // is exactly where the straight leg between them is drawn.
        let middle = CGVector(
            dx: (ends[0].dx + ends[1].dx) / 2,
            dy: (ends[0].dy + ends[1].dy) / 2
        )
        map.coordinate(withNormalizedOffset: middle).tap()

        XCTAssertTrue(
            element("trail-draft-point-3", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "tapping the leg should put a third point down"
        )
        // And it went into the middle rather than onto the end: a point
        // appended out there would have made the trail visibly longer, and a
        // point on the line between two others adds nothing to it.
        XCTAssertEqual(
            element("trail-draft-length", in: app).label,
            length,
            "a point inserted on the line should not lengthen the trail"
        )
    }

    /// Reordering, reached the way the hikes list taught: a context menu, then
    /// edit mode, then the list's own drag, then the way out.
    ///
    /// A long press straight onto a drag does nothing — `List` reorders only in
    /// edit mode — and the drag itself has to be slow and held, because a
    /// reorder commits on the drop. Both were paid for once on `HikeOrderUITests`
    /// and neither is rediscovered here.
    @MainActor
    func testReorderingThePoints() {
        let app = launchApp()
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTheMaker(in: app)
        draw(Self.drawnPoints, on: map, in: app)
        let length = element("trail-draft-length", in: app).label

        let third = element("trail-draft-point-3", in: app)
        let second = element("trail-draft-point-2", in: app)
        third.press(forDuration: 1.0)
        let reorder = app.buttons["Reorder Points"]
        XCTAssertTrue(
            reorder.waitForExistence(timeout: UITestTimeout.existence),
            "a long press on a point should offer to rearrange the line"
        )
        reorder.tap()
        let done = element("trail-draft-reorder-done", in: app)
        XCTAssertTrue(
            done.waitForExistence(timeout: UITestTimeout.existence),
            "taking the offer should put the list into reorder mode"
        )

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

        done.tap()
        XCTAssertTrue(
            waitUntil { element("trail-draft-actions", in: app).exists },
            "leaving reorder mode should hand the menu back"
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

        openTheMaker(in: app)
        draw(Self.lopsidedPoints, on: map, in: app)
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

        openTheMaker(in: app)
        draw(Self.drawnPoints, on: map, in: app)

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
