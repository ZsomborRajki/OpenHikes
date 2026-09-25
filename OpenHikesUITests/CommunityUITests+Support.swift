//
//  CommunityUITests+Support.swift
//  OpenHikesUITests
//
//  The seeded database as this bundle knows it, and the three gestures every
//  community scenario starts with.
//
//  The constants are duplicated from ``SeededCommunityTransport`` rather than
//  shared, for the reason `UITestFixture`'s trace is duplicated from
//  `UITestRecordingFixture`: this bundle runs out of process and cannot import
//  the app. Spelled the same way on both sides so a change to one is visibly a
//  change to the other.
//

import CoreLocation
import XCTest

/// What `--ui-test-community=seeded` puts in the public database.
nonisolated enum SeededHike {
    /// Anna's two, and Bern's one. The split is the point: blocking Anna has
    /// to leave a row behind, or a scenario cannot tell a block from a
    /// failure.
    static let ridgeTitle = "Thumsee Ridge Traverse"
    static let lakeTitle = "Lakeside Circuit"
    static let scrambleTitle = "Ostwand Scramble"

    static let allTitles = [ridgeTitle, lakeTitle, scrambleTitle]

    /// Only the ridge carries photographs, so an import *with* pictures and an
    /// import without them both have somewhere to happen.
    static let ridgePhotoCount = 2
}

/// What `--ui-test-community=curated` adds beside the published hikes.
///
/// Mirrors ``SeededCuratedTrailSource``'s two routes, and they are a pair for
/// the reason that file gives: the differences worth asserting are differences
/// *between* rows, so one carries every fact a signpost can and the other
/// carries almost none.
nonisolated enum SeededCuratedTrail {
    /// Fully tagged: `roundtrip=yes`, an `osmc:symbol`, both ends, a via, an
    /// operator and a website.
    static let loopTitle = "Lattenberg Rundweg"
    /// Nothing but a name and a network, so its shape is derived from the
    /// line's two ends and it has no waymark at all.
    static let pathTitle = "Schwarzbach Steig"

    static let allTitles = [loopTitle, pathTitle]

    /// The two parts ``CommunityHikeRow`` spends a curated row's subtitle on,
    /// as the loop's tags spell them. Both are words rather than pictures,
    /// which is what makes the row assertable at all — the signpost glyph is
    /// `accessibilityHidden`, like every other decoration in that row.
    static let loopShape = "Loop"
    static let loopWaymark = "Red waymark 7"
}

/// What `--ui-test-community=seeded` puts on a trail that somebody *else*
/// published.
///
/// Mirrors ``SeededCommunityTransport``'s own constants. Cass is a third
/// person, deliberately: with the contributor sharing an identity with one of
/// the two authors, blocking one and blocking the other could not be told
/// apart.
nonisolated enum SeededContribution {
    static let author = "Cass"
    /// Three, and they are on a hike whose own author published none — so a
    /// strip on that screen is the contributed photographs and nothing else.
    static let photoCount = 3
}

/// Which stand-in database a scenario asks for. Mirrors
/// ``SeededCommunityTransport.Scenario``.
nonisolated enum SeededCommunityScenario: String {
    /// ``seeded``, plus the two OpenStreetMap routes.
    ///
    /// The only way to reach a *mixed* list from automation, which is the one
    /// the shipping app draws — see ``SeededCuratedTrailSource``.
    case curated = "curated"
    case empty = "empty"
    case failing = "failing"
    /// ``seeded``, with a reviewer who has said yes — the only way to reach a
    /// *published* hike from automation, since `publication(of:)` is what
    /// writes ``Hike/communityListingID`` and nothing else does.
    case published = "published"
    /// ``seeded``, with a queue in front of it — the only way to reach the
    /// review section from automation, since in production an empty queue is
    /// what the *server* gives everybody who is not a reviewer.
    case reviewing = "reviewing"
    case seeded = "seeded"
    /// ``published``, and then not — one yes from `publication(of:)` and `nil`
    /// after it. The only way automation reaches a hike that was believed live
    /// and then found gone. Mirrors ``SeededCommunityTransport/Scenario``.
    case takenDown = "takenDown"
}

/// What `--ui-test-community=reviewing` puts in the reviewer's queue.
///
/// Mirrors ``SeededCommunityTransport``'s own constants. Shares no word with
/// ``SeededHike``'s titles, so a scenario asserting that the queue and the
/// browse list are separate cannot be fooled by a match across both.
nonisolated enum SeededQueuedHike {
    static let title = "Karwendel Hut Approach"
    static let photographedTitle = "Steinerne Rinne"
    static let allTitles = [title, photographedTitle]
    /// How many photographs ``photographedTitle`` arrives with, once its
    /// preview has downloaded them. Mirrors
    /// ``SeededCommunityTransport``'s own constant.
    static let photoCount = 2
}

/// How many screens ``XCTestCase/awaitCommunityAnswer(_:in:)`` walks before
/// turning round.
///
/// The merged list is a page of twenty-five at most and four rows fit on a
/// sheet at its middle detent, so four screens reaches the bottom of anything
/// these scenarios seed with room to spare. It is a bound rather than a
/// measurement: what it has to be is *enough*, and a sweep that overshoots
/// costs a swipe against a list that has stopped moving.
private let communityListSweepScreens = 4

extension XCTestCase {
    /// A launch with a stand-in public database, a fix on the fixture
    /// trailhead, and the sheet already open.
    ///
    /// The location is not optional decoration. ``CommunityBrowser`` asks its
    /// question about a *region*, and a launch with no fix leaves the map
    /// wherever it starts — so the browse either sits on a spinner or reports
    /// that the hiker is zoomed too far out, and neither is the screen these
    /// scenarios are about.
    @MainActor
    @discardableResult func launchCommunity(
        scenario: SeededCommunityScenario,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-community=\(scenario.rawValue)",
            ] + extraArguments
        )
        // Deliberately no `resetAuthorizationStatus(for: .location)`. These
        // scenarios only need the app to know roughly where it is, and the
        // reset is the call the release review caught hanging for thirty
        // seconds on a contended runner. Whatever a clone's last scenario left
        // behind, the monitor below grants the prompt if one appears and
        // nothing asks for one if it does not.
        //
        // Dropping it from the other three classes was tried against this
        // run and put back: see the issue this change closes. None of them
        // asserts on the prompt, but the recording scenarios do depend on
        // the state the reset produces, and `startRecording`'s opening
        // `app.tap()` depends on there being an alert for it to be spent on.
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        addTeardownBlock { @MainActor in XCUIDevice.shared.location = nil }
        return launch(app)
    }

    /// Selects the Community half of the sheet's picker, which is also the
    /// browse session's opt-in — see ``MapSheetCommunitySection``.
    /// The segments are matched on the app rather than through the picker's
    /// own identifier. A `Picker` puts that identifier on a container the
    /// accessibility tree exposes inconsistently — reliably on a freshly drawn
    /// sheet, not reliably on one a pushed screen has just been popped off —
    /// while the two segments are always there as buttons, because they are
    /// what a hiker taps.
    @MainActor
    func selectCommunityTab(in app: XCUIApplication) {
        let community = app.buttons["Community"]
        // The launch-scale wait rather than the existence one. This is the
        // first element a community scenario asks for after `launch()` returns,
        // and the app reaching the foreground is not the same event as the
        // sheet having drawn its picker — on a machine running three simulator
        // clones at once the gap between them is seconds. Every later wait in
        // these scenarios is about the app doing something; this one is about
        // it having started.
        XCTAssertTrue(
            community.waitForExistence(timeout: UITestTimeout.trace),
            "a launch with a community transport should offer the Community segment"
        )
        // Until it is selected rather than once: in dark appearance the
        // first tap on a segmented picker is lost — see
        // ``tapUntilSelected(_:timeout:)``. Screenshot frame 03 failed both
        // dark attempts on it before this.
        XCTAssertTrue(tapUntilSelected(community), "tapping Community should select it")
        searchThisAreaIfOffered(in: app)
    }

    /// Asks about the area the map has settled on, if the browser is offering
    /// to.
    ///
    /// Not a workaround for the test's benefit — it is the gesture the feature
    /// is built around. The sheet opens before the simulated fix arrives, the
    /// map then moves to it, and a new region is a new question the hiker did
    /// not ask: ``CommunityQueryPolicy`` puts up *Search this area* rather
    /// than spending a query on a map that is still moving. A scenario that
    /// skipped this would be asserting against the region the map happened to
    /// start in, which is not where the seeded hikes are.
    ///
    /// **This is the wait that was mis-set, and it failed silently.** It was a
    /// ten-second `waitForExistence` followed by `guard … else { return }`, so
    /// on a clone that had not drawn the pill within ten seconds the gesture
    /// was skipped and the run carried on against whatever region the map
    /// started in — and the failure then arrived, much later and somewhere
    /// else, as a seeded row that "should be listed". Six of the eight
    /// failures in a `--all` run on a clean `main` were that sentence.
    ///
    /// It now waits for the browser to have *answered*, which is the question
    /// the caller is really asking. Three things end the wait: the pill, which
    /// is tapped; a row, which means the search already ran; or the state row,
    /// which is what an area with nothing in it draws. Budgeted at launch
    /// scale for the reason ``selectCommunityTab(in:)`` gives — this happens
    /// within a second or two of `launch()` returning, and on a machine
    /// running three clones the gap between the app being foregrounded and the
    /// sheet having settled is seconds. It costs that budget only when nothing
    /// at all happens, which is a failure either way.
    @MainActor
    func searchThisAreaIfOffered(in app: XCUIApplication) {
        let pill = element("community-search-this-area", in: app)
        let state = element("community-nearby-empty", in: app)
        let anyRow = app.descendants(matching: .any)
            .matching(identifier: "community-hike-row")
            .firstMatch
        // The pill keeps its original grace period before the state row is
        // allowed to end the wait, and that ordering is load-bearing rather
        // than tidy. The state row is what an area with nothing in it draws
        // *and* what a browser that has not searched yet draws, so returning
        // on it immediately skips the gesture in exactly the scenario that
        // needs it most: `.failing` reports through that row, and the failure
        // and its *Try Again* only exist once a search has been asked for.
        let grace = Date().addingTimeInterval(UITestTimeout.navigation)

        _ = waitUntil(timeout: UITestTimeout.trace) {
            if pill.exists {
                pill.tap()
                return true
            }
            if anyRow.exists { return true }
            return state.exists && Date() > grace
        }
    }

    /// Waits for `target` while re-offering *Search this area*.
    ///
    /// The wait every community scenario needs and only one of them used to
    /// have. The map can settle **twice** — the sheet opens before the
    /// simulated fix arrives — so the pill can come back after
    /// ``selectCommunityTab(in:)`` already dealt with one, and anything waited
    /// for through that is waited for in vain: the browser is not going to
    /// answer a question nobody asked. A bare `waitForExistence` therefore
    /// fails on exactly the machine where the second settle is slow, which is
    /// a machine running three simulator clones.
    ///
    /// Both halves matter, and the second is the one that gets left out.
    /// Raising the timeout alone was tried in ``openCommunityHike(titled:in:)``
    /// and is recorded there as insufficient — the wait has to *re-offer* the
    /// gesture, not merely wait longer for its consequences.
    ///
    /// Budgeted at launch scale for the reason ``selectCommunityTab(in:)``
    /// gives. It costs that budget only when nothing happens at all, which is
    /// a failure either way.
    /// **A row that is not in the element tree is two different failures, and
    /// this used to answer only one of them.** `List` builds its rows lazily,
    /// so a row the browser has already returned is absent from the tree
    /// until the list has been scrolled to it — which reads exactly like a
    /// half that never answered. The merged list is five rows against a sheet
    /// that shows four, and the curated pair sorts behind all three published
    /// hikes, so the last row was permanently past the fold: the browser had
    /// answered correctly, the pill was tapped fifty times over forty
    /// seconds, and the wait reported that the row "should be listed".
    ///
    /// So each poll walks one screen as well as asking again. It walks
    /// **both ways**, because a case asks about five titles and the merge
    /// decides which row is which — the row wanted next is as often above the
    /// last one as below it. The step counter is what makes going back up
    /// safe: `swipeDown` with the list already at its top is a gesture on the
    /// *sheet*, which would resize the screen under the test rather than
    /// scroll it, so this never swipes down more times than it has swiped up.
    @MainActor
    @discardableResult func awaitCommunityAnswer(
        _ target: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        let pill = element("community-search-this-area", in: app)
        let container = scrollContainer(in: app)
        // How far this sweep has walked the list down, so it can walk back.
        var walked = 0
        return waitUntil(timeout: UITestTimeout.trace) {
            // Reachable rather than merely present: the callers read this
            // row's label or tap it, and a row hanging off the bottom edge
            // answers `exists` while neither of those works. See
            // ``XCTestCase/isReachable(_:in:)``.
            if isReachable(target, in: app) { return true }
            if pill.exists { pill.tap() }
            if walked < communityListSweepScreens {
                container.swipeUp()
                walked += 1
            } else if walked > 0 {
                container.swipeDown()
                walked -= 1
            }
            return isReachable(target, in: app)
        }
    }

    /// The other half of the picker: the hiker's own hikes.
    @MainActor
    func selectMyHikesTab(in app: XCUIApplication) {
        let mine = app.buttons["My Hikes"]
        XCTAssertTrue(
            mine.waitForExistence(timeout: UITestTimeout.existence),
            "the picker should still offer the hiker's own list"
        )
        mine.tap()
    }

    /// A published hike's row.
    ///
    /// ``CommunityHikeRow`` combines its children into one element, like the
    /// hiker's own rows, so the title is matched against the row's label
    /// rather than looked up as a static text of its own.
    @MainActor
    func communityRow(
        titled title: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "community-hike-row")
            .matching(NSPredicate(format: "label CONTAINS %@", title))
            .firstMatch
    }

    /// The preview's Photos heading.
    ///
    /// Drawn only when there are files to draw under it, which makes its
    /// presence exactly the fact worth asserting: the photographs were
    /// downloaded and are on screen. The tiles themselves are reachable too —
    /// see ``communityPhotoTile(at:in:)`` — but the heading is the one that
    /// answers without naming a particular picture.
    @MainActor
    func communityPhotoStrip(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Photos"]
    }

    /// One picture in the preview's strip, by its place in the submission.
    ///
    /// ``CommunityPhotoTile`` is still `accessibilityHidden` — a stranger's
    /// photograph says nothing to a screen reader that the button around it
    /// has not already said — so this is the *button*, which carries the name
    /// and opens ``CommunityPhotoViewer`` at that picture.
    @MainActor
    func communityPhotoTile(at index: Int, in app: XCUIApplication) -> XCUIElement {
        element("community-photo-\(index)", in: app)
    }

    /// Opens a published hike and waits for the preview to have finished
    /// loading — which is the route, the photographs and the page built off
    /// them, not merely the screen being pushed.
    @MainActor
    func openCommunityHike(titled title: String, in app: XCUIApplication) {
        let row = communityRow(titled: title, in: app)
        XCTAssertTrue(
            awaitCommunityAnswer(row, in: app),
            "\"\(title)\" should be listed before it can be opened"
        )
        row.tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) {
                !element("community-hike-loading", in: app).exists
            },
            "the preview for \"\(title)\" never finished loading"
        )
    }
}
