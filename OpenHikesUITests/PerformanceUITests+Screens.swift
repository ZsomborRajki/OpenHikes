//
//  PerformanceUITests+Screens.swift
//  OpenHikesUITests
//
//  The screens that shipped without a number: settings, photo discovery, and
//  the photo viewer's own body.
//
//  Everything measured in the other files is on a path somebody already
//  suspected — a GPS fix, a pan, a scrub. These three are the opposite case.
//  They are ordinary screens, reached by tapping a button, doing work nobody
//  described as high-frequency, and each one turned out to be re-rendering far
//  more than it draws. That is the argument for measuring a feature when it
//  lands rather than when it is suspected: none of the three looked wrong, and
//  reading the code did not say so either.
//
//  Two of these budgets are about a *selection*, which is the shape worth
//  naming. Ticking a checkbox, opening a sheet, turning a page — all three are
//  "one thing changed, redraw the one thing". A screen that answers them by
//  rebuilding its whole content is not slow at eight items and is unusable at
//  two hundred, and the count is flat in between, so a budget stated per
//  interaction catches it while it is still cheap.
//

import XCTest

extension PerformanceUITests {
    /// Enough matches to fill the review grid and give a tap something to be
    /// cheap or expensive against. Every one is a synthetic library asset
    /// offered through the shipping matcher.
    private static let libraryMatches = 12
    /// How many cells the selection phase ticks. More than one, because a
    /// per-tap cost is what is being measured and a single tap cannot
    /// distinguish a constant from a rate.
    private static let selectionTaps = 4

    // MARK: - Settings

    /// The settings sheet is seven sections in one `Form`, and it is the
    /// screen most likely to be open while something else is writing.
    ///
    /// It declares `@Query private var hikes: [Hike]` and its body renders no
    /// hike at all — the query feeds the offline-storage measurement, which is
    /// `.task`-driven. That combination is invisible by reading: `@Query` is a
    /// `DynamicProperty`, so it invalidates the view that *declares* it
    /// whether or not the body reads it, and every write to any `Hike` from
    /// anywhere therefore costs all seven sections.
    ///
    /// The phase drives the one writer that is reachable from this screen —
    /// `Clear Map Cache`, which flushes auto-saved tile keys into every hike's
    /// manifest before it measures — and asserts the sheet does not answer a
    /// storage write by rebuilding the subscription rows, the provider list
    /// and the field-metrics section along with it.
    @MainActor
    func testSettingsDoesNotFollowTheHikeStore() {
        let app = launch(
            scenario: "settings",
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        awaitImportedHike(in: app)
        settle(in: app)

        element("settings-button", in: app).tap()
        let screen = element("settings-screen", in: app)
        XCTAssertTrue(
            screen.waitForExistence(timeout: UITestTimeout.launch),
            "the settings button should present the settings sheet"
        )
        // The two `.task`s on this screen measure disk, which finishes after
        // the sheet appears and re-renders it when it lands.
        settle(in: app)

        // Toggling a preference is the cheapest real interaction this screen
        // offers, and the one whose cost should be bounded by the control that
        // changed rather than by the size of the form around it.
        let toggle = element("save-photos-to-library-toggle", in: app)
        XCTAssertTrue(
            scrollIntoView(toggle, in: app),
            "the photos section should offer its library switch"
        )
        // Warmed on the switch itself rather than on the form around it. The
        // centre of this screen is the provider list, and
        // `warmAccessibilityTree` pays its cost with a *real* tap — which
        // there would either change the map source or open the paywall.
        warmAccessibilityTree(around: toggle, in: app)

        let flipping = measurePhase(named: "settings-toggle", in: app, seconds: 1) {
            toggle.tap()
            toggle.tap()
        }

        // Two flips of one switch. The `Form` re-evaluating once per flip is
        // the price of an `@AppStorage` that genuinely changed; more than that
        // means something else is invalidating alongside it.
        assertNoMoreThan(3, of: "SettingsBody", in: flipping, phase: "settings-toggle")
        // And nothing behind the sheet. The map, the bottom sheet and the hike
        // list are all covered — a body from any of them is work drawn nowhere.
        assertNoMoreThan(0, of: "OpenHikesViewBody", in: flipping, phase: "settings-toggle")
        assertNoMoreThan(0, of: "MapSheetBody", in: flipping, phase: "settings-toggle")
        assertNoMoreThan(0, of: "MapSheetHikesBody", in: flipping, phase: "settings-toggle")
        assertNoStall(in: flipping, phase: "settings-toggle")

        // The storage half. `Clear Map Cache` calls `claimSnapshots()`, which
        // flushes pending auto-saved tile keys into the hikes' manifests — a
        // SwiftData write to `Hike`, made by this screen, from this screen.
        // While the query lived here that write came straight back as another
        // full-form pass, which is a screen invalidating itself.
        let clear = app.buttons["Clear Map Cache"]
        guard scrollIntoView(clear, in: app), clear.isEnabled else {
            // Nothing cached means nothing to flush and nothing to measure.
            // Skipped rather than failed: which tiles a scenario happens to
            // have drawn is not this test's subject.
            finish(in: app)
            return
        }
        let clearing = measurePhase(named: "settings-clear-cache", in: app, seconds: 2) {
            clear.tap()
        }

        // The button nils the usage readout, the measurement lands, and the
        // rows redraw — three passes is the honest cost of that round trip.
        // What must not be in here is a pass per hike written.
        assertNoMoreThan(4, of: "SettingsBody", in: clearing, phase: "settings-clear-cache")
        assertNoMoreThan(0, of: "MapSheetHikesBody", in: clearing, phase: "settings-clear-cache")
        assertNoStall(in: clearing, phase: "settings-clear-cache")
        finish(in: app)
    }

    // MARK: - Photo discovery

    /// Ticking one checkbox in the review grid.
    ///
    /// The selection is held by `PhotoDiscoveryController`, and the question is
    /// only ever which view *reads* it. Read by the cell, a tap redraws one
    /// square. Read anywhere in the sheet's own body — including from a
    /// `func cell(...)` that looks like it belongs to the cell and does not —
    /// a tap rebuilds every visible tile, re-runs each one's accessibility
    /// label, and re-formats each one's timestamp.
    ///
    /// That is a per-tap cost proportional to the grid, on a screen whose whole
    /// purpose is to be tapped repeatedly.
    @MainActor
    func testPhotoDiscoverySelectionStaysInsideTheCell() {
        let app = launch(
            scenario: "photo-discovery",
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-photo-library=\(Self.libraryMatches)",
            ]
        )
        awaitImportedHike(in: app)
        openHikeDetail(in: app)
        settle(in: app)

        let discover = element("photo-discovery-button", in: app)
        XCTAssertTrue(
            scrollIntoView(discover, in: app),
            "a hike with a timed route should offer to look for photos of it"
        )
        let grid = element("photo-discovery-grid", in: app)
        // Presenting the sheet has to build it. Measured only so the budgets
        // below cannot pass by saying nothing: if `PhotoDiscoveryBody` is ever
        // renamed or removed, every "no more than" assertion in this test
        // reads zero and succeeds, and this one fails instead.
        //
        // The tap is inside the window rather than before it, because the
        // presentation is the whole of what this phase measures. It used to
        // sit outside, and the floor below still passed — on a re-evaluation
        // the sheet owed to `@Environment(\.dismiss)` rather than to the
        // gesture. With that gone the phase measured zero, which is the
        // assertion doing its job: the sheet's own build had always been
        // finishing before the baseline reading was taken.
        let opening = measurePhase(named: "discovery-open", in: app, seconds: 2) {
            discover.tap()
            XCTAssertTrue(
                grid.waitForExistence(timeout: UITestTimeout.launch),
                "the seeded library photos should reach the review grid"
            )
        }
        assertAtLeast(1, of: "PhotoDiscoveryBody", in: opening, phase: "discovery-open")
        // The search runs against the photo library and the thumbnails arrive
        // one at a time; measuring before that finishes would charge the taps
        // for the grid filling in.
        settle(in: app)

        let first = element("discovered-photo-0", in: app)
        XCTAssertTrue(
            first.waitForExistence(timeout: UITestTimeout.launch),
            "each match should be a reviewable tile"
        )
        warmAccessibilityTree(around: element("photo-discovery-selection-count", in: app), in: app)

        let ticking = measurePhase(named: "discovery-select", in: app, seconds: 1) {
            for index in 0..<Self.selectionTaps {
                element("discovered-photo-\(index)", in: app).tap()
            }
        }

        // The count is the whole finding. One sheet body per tap means the
        // selection is an input of the sheet rather than of the cell, and the
        // grid — every visible cell, every label, every date — was rebuilt for
        // a tick mark. It measured 4.0 for these four taps before the cell
        // became a leaf and 0 after; budgeted at 1 rather than 0 so a single
        // unrelated re-evaluation does not flake, while still catching the
        // per-tap shape this exists to prevent.
        assertNoMoreThan(1, of: "PhotoDiscoveryBody", in: ticking, phase: "discovery-select")
        // Nothing outside the sheet, which covers the hike screen entirely.
        assertNoMoreThan(0, of: "HikeDetailBody", in: ticking, phase: "discovery-select")
        assertNoMoreThan(0, of: "HikePhotoSectionBody", in: ticking, phase: "discovery-select")
        assertNoMoreThan(0, of: "OpenHikesViewBody", in: ticking, phase: "discovery-select")
        assertNoMoreThan(0, of: "MapSheetHikesBody", in: ticking, phase: "discovery-select")
        // A tick mark is not a reason to touch the photo library.
        assertNoMoreThan(0, of: "PhotoThumbnailDecoded", in: ticking, phase: "discovery-select")
        assertNoStall(in: ticking, phase: "discovery-select")

        // Select All is one write to the same selection set. Kept separate
        // because it is the case where redrawing every cell would be honest
        // work — but it measured 0 sheet bodies too, since the cells observe
        // the selection themselves now.
        let selectAll = element("photo-discovery-select-all-button", in: app)
        XCTAssertTrue(selectAll.waitForExistence(timeout: UITestTimeout.launch))
        let bulk = measurePhase(named: "discovery-select-all", in: app, seconds: 1) {
            selectAll.tap()
        }
        assertNoMoreThan(1, of: "PhotoDiscoveryBody", in: bulk, phase: "discovery-select-all")
        assertNoStall(in: bulk, phase: "discovery-select-all")

        // Leaving and returning must not rebuild this sheet at all. It is the
        // one screen in the suite that is still up when the run ends, which is
        // what made it the place a scene transition's render cost showed:
        // `@Environment(\.dismiss)` declared on the sheet had it re-evaluated
        // 27 times across the four transitions below — eight of them inside a
        // single backgrounding, rebuilding a twelve-cell grid and every cell's
        // accessibility label for a screen that was on its way off the
        // display. It reads 0 now.
        //
        // Budgeted against the transitions rather than at zero, on the same
        // argument `background-recording` makes: one pass through the
        // hierarchy per transition is a cost this app has always paid and may
        // pay again, and what must not come back is a cost *per frame of the
        // transition*.
        let closing = finish(in: app)
        let transitions = closing.count(of: "ScenePhaseChanged")
        XCTAssertGreaterThan(transitions, 0, "the app never actually backgrounded")
        assertNoMoreThan(
            transitions,
            of: "PhotoDiscoveryBody",
            in: closing,
            phase: "finish"
        )
    }
}
