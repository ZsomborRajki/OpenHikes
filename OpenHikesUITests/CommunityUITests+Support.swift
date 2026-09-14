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

/// Which stand-in database a scenario asks for. Mirrors
/// ``SeededCommunityTransport.Scenario``.
nonisolated enum SeededCommunityScenario: String {
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
        community.tap()
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
    @MainActor
    @discardableResult func awaitCommunityAnswer(
        _ target: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        let pill = element("community-search-this-area", in: app)
        return waitUntil(timeout: UITestTimeout.trace) {
            if target.exists { return true }
            if pill.exists { pill.tap() }
            return false
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

    /// The preview's Photos heading, which is the only part of the strip a
    /// test can see.
    ///
    /// ``CommunityPhotoTile`` is `accessibilityHidden` on purpose — a
    /// stranger's unlabelled photographs say nothing to a screen reader that
    /// the photo count above them has not already said — so the tiles
    /// themselves are not elements. The heading is drawn only when there are
    /// files to draw under it, which makes its presence exactly the fact worth
    /// asserting: the photographs were downloaded and are on screen.
    @MainActor
    func communityPhotoStrip(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Photos"]
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
