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
    case seeded = "seeded"
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
        // Deliberately no `resetAuthorizationStatus(for: .location)`. The
        // recording scenarios reset because they assert on the prompt's own
        // consequences; these only need the app to know roughly where it is,
        // and the reset is the call the release review caught hanging for
        // thirty seconds on a contended runner — the two failures in that
        // review's full UI run were both this, and both passed on a rerun.
        // Whatever a clone's last scenario left behind, the monitor below
        // grants the prompt if one appears and nothing asks for one if it
        // does not.
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
    @MainActor
    func searchThisAreaIfOffered(in app: XCUIApplication) {
        let pill = element("community-search-this-area", in: app)
        guard pill.waitForExistence(timeout: UITestTimeout.navigation) else { return }
        pill.tap()
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
            row.waitForExistence(timeout: UITestTimeout.existence),
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
