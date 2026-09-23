//
//  AccessibilityUITests.swift
//  OpenHikesUITests
//
//  The sweep, run once per screen.
//
//  `performAccessibilityAudit` walks the live element tree and reports
//  unlabelled controls, clipped text at large type sizes, contrast failures
//  and hit regions too small to reach — the class of regression that arrives
//  quietly, in a view nobody thought to re-check. It is per screen rather than
//  once because it only ever sees what is on screen at the time, which is why
//  a screen with no test here has no coverage at all.
//
//  What the audit cannot know — that a tile-provider row is *the selected*
//  one, that the elevation graph reads out the point under the tracker — is
//  asserted in ``AccessibilityLabelUITests`` instead. The exclusions, and the
//  argument for each, live in `AccessibilityAuditSupport.swift`.
//
//  Out-of-process, so nothing here can import the app; screens are reached
//  with the same launch arguments and helpers the functional tests use (see
//  `UITestSupport.swift`).
//

import XCTest

nonisolated final class AccessibilityUITests: XCTestCase {
    /// The first screen: the map, the weather badge and the sheet's search
    /// row. Element detection is the check that matters most here, since two
    /// of the controls are glyph-only buttons.
    @MainActor
    func testMapAndSheetPassAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)

        try audit(app)
    }

    @MainActor
    func testHikeDetailPassesAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)
        XCTAssertTrue(
            element("elevation-chart", in: app)
                .waitForExistence(timeout: UITestTimeout.existence)
        )

        try audit(app)
    }

    @MainActor
    func testSettingsPassesAccessibilityAudit() throws {
        let app = launchApp()
        openSettings(in: app)

        try audit(app)
    }

    /// The published hikes list, which no audit had ever seen.
    ///
    /// ``OpenHikesModel/makeCommunityTransport()`` hands back `nil` for a test
    /// launch, so the picker, the list and everything behind them were absent
    /// from every sweep in this file — a screen full of somebody else's titles,
    /// distances and credits, shipped without once being read the way a
    /// screen reader reads it. `--ui-test-community=seeded` is what makes it
    /// reachable; see ``SeededCommunityTransport``.
    @MainActor
    func testCommunityListPassesAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        // The same wait `openCommunityHike` makes, for the same reason: the map
        // can settle twice, and a list waited for through the second settle is
        // a list that never answers. A bare `waitForExistence` here is what
        // made this the audit that fails on a busy machine — and it failed
        // saying the list had not answered, which was true and not the fault
        // of anything it was about to audit.
        XCTAssertTrue(
            awaitCommunityAnswer(communityRow(titled: SeededHike.ridgeTitle, in: app), in: app),
            "the audit is worth nothing against a list that has not answered yet"
        )

        try audit(app)
    }

    /// The preview, which is the densest screen in the feature: a chart, a
    /// grid of stats, a strip of a stranger's photographs and two moderation
    /// actions, all about a hike the hiker does not own yet.
    @MainActor
    func testCommunityPreviewPassesAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)
        XCTAssertTrue(
            element("community-import-button", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the preview should have finished loading before it is swept"
        )

        try audit(app)
    }

    /// The publish form, which is the consequential one.
    ///
    /// A text field the hiker types a display name into, the disclosure footer
    /// `CommunityShareDisclosureTests` pins the wording of, the photo count,
    /// and a button that sends a hike to a database every other user reads.
    /// Nothing else in the app is a form of comparable consequence, and it had
    /// never been swept: the two community audits that existed covered the
    /// list and the preview, both of which are screens to *read*.
    @MainActor
    func testCommunityShareFormPassesAccessibilityAudit() throws {
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)
        tapWhenReady(element("community-share-button", in: app))
        XCTAssertTrue(
            element("community-author-field", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the audit is worth nothing against a form that has not drawn yet"
        )

        try audit(app)
    }

    /// The report form: a reason picker, a free-text note, and the commitment
    /// footer.
    ///
    /// One half of the Guideline 1.2 pair, and the half a reviewer is most
    /// likely to open. Driven by the functional suite already — which does not
    /// run in CI, deliberately — so until now it had working automation and
    /// none that gates a merge.
    @MainActor
    func testCommunityReportFormPassesAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)
        tapWhenReady(element("community-actions-menu", in: app))
        tapWhenReady(element("community-report-button", in: app))
        XCTAssertTrue(
            element("community-report-reason", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the report form should have asked its question before it is swept"
        )

        try audit(app)
    }

    /// Settings *with* a blocked author in it.
    ///
    /// ``BlockedHikersSection`` is absent rather than empty for anybody who has
    /// never blocked anyone, which is right for the screen and meant
    /// `testSettingsPassesAccessibilityAudit` walked a Settings that never
    /// contained it. Its rows — a name, a date and an Unblock control each —
    /// had never been audited. Blocking one author first is the whole
    /// difference.
    @MainActor
    func testBlockedHikersSectionPassesAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)
        tapWhenReady(element("community-actions-menu", in: app))
        tapWhenReady(element("community-block-button", in: app))
        tapWhenReady(element("community-block-confirm", in: app))
        // Bern's hike is half of this wait, and it is the half that makes the
        // other half mean anything. A row's *absence* is also what the screen
        // looks like from behind the detail sheet the block is taken from —
        // the list is not in the hierarchy at all there — so waiting on the
        // ridge alone passes the instant the sheet is tapped, before the block
        // has landed and before the pop that would apply it. The rest of the
        // test then audits a Settings screen with no Blocked section in it and
        // reports a missing section, which is exactly what this failed as on a
        // busy machine. The lake row is the one a block on Anna leaves behind:
        // waiting for it says the list is back, and only then does the ridge
        // being gone say a block was applied to it.
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) {
                communityRow(titled: SeededHike.lakeTitle, in: app).exists
                    && !communityRow(titled: SeededHike.ridgeTitle, in: app).exists
            },
            "the section is drawn from a block, so the block has to have landed"
        )

        openSettings(in: app)
        let unblockAll = element("unblock-everyone", in: app)
        XCTAssertTrue(
            scrollUntilVisible(unblockAll, in: app),
            "a device with a blocked author should show the Blocked section"
        )

        try audit(app)
    }

    /// The recording screen is the one a hiker uses without looking at it, so
    /// its live numbers have to be readable and its phase has to be announced.
    @MainActor
    func testRecordingScreenIsReadable() throws {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let phase = element("recording-phase", in: app)
        XCTAssertTrue(
            phase.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertFalse(
            phase.label.isEmpty,
            "the phase dot is a colour, so the word beside it has to be spoken"
        )

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        XCTAssertEqual(points.label, "Points")
        XCTAssertNotNil(points.value as? String)

        try audit(app)
    }

    /// The review screen, which is the one place in the app where a decision
    /// is drawn as a tint and a checkmark.
    ///
    /// A choice that reads as two identical unnamed rows is unusable without
    /// sight, and this screen has no second way to tell them apart: the
    /// difference between them is the shape of a line on a map.
    @MainActor
    func testRouteReviewIsReadable() throws {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph=\(UITestFixture.trailGraphName)",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.reviewableTrace[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        walkRecordedTrace(UITestFixture.reviewableTrace, countedBy: points)
        stopRecording(named: Self.reviewedHikeName, in: app)

        let title = element("review-section-title", in: app)
        XCTAssertTrue(
            title.waitForExistence(timeout: Self.reviewTimeout),
            "a snapped recording should stop in review"
        )
        XCTAssertFalse(
            title.label.isEmpty,
            "which stretch is being decided has to be said, not just drawn"
        )

        let keepTrail = element("review-choice-trail", in: app)
        let useGPS = element("review-choice-gps", in: app)
        XCTAssertTrue(keepTrail.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertFalse(
            keepTrail.label.isEmpty,
            "each option has to name the line it would keep"
        )
        XCTAssertFalse(useGPS.label.isEmpty)
        XCTAssertTrue(
            keepTrail.isSelected,
            "the standing choice is drawn as a checkmark, which is decoration "
                + "— the trait is what carries it"
        )
        XCTAssertFalse(useGPS.isSelected)

        try audit(app)
    }

    /// The photo strip and the viewer it opens, seeded because the Simulator
    /// has no camera.
    ///
    /// A tile is a picture and nothing else, so its label is the only thing
    /// distinguishing one from the next; the viewer's toolbar is two glyphs,
    /// both destructive-adjacent, both unnamed without help.
    @MainActor
    func testPhotoGalleryIsReadable() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=2",
            ]
        )
        openHikeDetail(in: app)

        let strip = element("hike-photo-strip", in: app)
        XCTAssertTrue(
            scrollIntoView(strip, in: app),
            "a hike with photos should show the strip they live on"
        )
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Photo 1 of 2"))
            .firstMatch
        XCTAssertTrue(
            tile.waitForExistence(timeout: UITestTimeout.existence),
            "a tile should say which photo of how many it is"
        )
        try audit(app)

        tile.tap()
        XCTAssertTrue(
            element("photo-viewer", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertEqual(
            app.buttons["Delete photo"].label,
            "Delete photo",
            "a trash glyph is not a label"
        )
        XCTAssertEqual(
            app.buttons["Show where this photo was taken"].label,
            "Show where this photo was taken"
        )
        XCTAssertTrue(
            app.buttons["Next photo"].isEnabled,
            "the step buttons are disabled rather than hidden at the ends, so "
                + "with two photos the first one has somewhere to go"
        )

        try audit(app)
    }

    /// The photo-discovery sheet, which is a grid of pictures and nothing else.
    ///
    /// A cell has no text in it, so its label is the whole of what separates
    /// one photograph from the next — and it has to say more than "photo": when
    /// it was taken and on what evidence it was placed, because that is what a
    /// hiker is deciding on when they tick it. The audit is run over the grid
    /// rather than only over the button that opens it, since a screen reached
    /// through a modal is a screen a sweep otherwise never sees.
    @MainActor
    func testPhotoDiscoveryIsReadable() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-photo-library=3",
            ]
        )
        openHikeDetail(in: app)

        let discover = element("photo-discovery-button", in: app)
        XCTAssertTrue(
            scrollIntoView(discover, in: app),
            "a hike with a timed route should offer to look for photos of it"
        )
        XCTAssertEqual(
            discover.label,
            "Find Photos of This Hike",
            "a magnifying glass is not a label"
        )
        discover.tap()

        XCTAssertTrue(
            element("photo-discovery-grid", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the matches should be offered for review"
        )
        let cell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Photo taken at"))
            .firstMatch
        XCTAssertTrue(
            cell.waitForExistence(timeout: UITestTimeout.existence),
            "a cell should say when its photo was taken and how it was placed"
        )
        XCTAssertTrue(
            cell.isSelected,
            "results arrive selected, and a tint is not something VoiceOver "
                + "can see: the trait is what says so"
        )

        try audit(app)
    }

    /// The empty state, which is a screen made almost entirely of glyphs
    /// interpolated into sentences.
    ///
    /// "Tap ⬇️ to import a GPX file" contributes nothing spoken where the
    /// symbol is, so each line carries a rewritten label naming the button it
    /// points at. This is also the only screen a first launch shows, which
    /// makes it the worst one to leave unreadable.
    @MainActor
    func testEmptyStateIsReadable() throws {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet"])

        let importPrompt = app.staticTexts[
            "Tap the Import GPX file button to import a GPX file."
        ]
        XCTAssertTrue(
            importPrompt.waitForExistence(timeout: UITestTimeout.existence),
            "the glyph in the sentence has to be spoken as the button it is"
        )
        XCTAssertTrue(
            app.staticTexts[
                "Or tap the Record a hike button to record one as you walk."
            ].exists
        )
        XCTAssertEqual(
            element("import-gpx-button", in: app).label,
            "Import GPX file",
            "and the button it names has to answer to that name"
        )
        XCTAssertEqual(
            element("record-hike-button", in: app).label,
            "Record a hike"
        )

        try audit(app)
    }

    /// Matching a trace against the bundled graph is real work on a cold
    /// simulator.
    private static let reviewTimeout: TimeInterval = 30
    private static let reviewedHikeName = "Reviewed Route"
}

// MARK: - The trail maker

/// In an extension for the reason ``OpenHikesView``'s own halves are: the
/// class above is at the body length the linter allows, and an extension is
/// not counted against it. The split is by feature rather than by size — every
/// screen below belongs to #607's maker.
extension AccessibilityUITests {
    /// The trail maker, which is the densest screen the app has added since
    /// the community preview: a travel-mode tray, a switch, a list of stops
    /// with a running length, time and climb on its header, and Save and the
    /// ✕ sharing one pill — over a map that is simultaneously a drawing
    /// canvas.
    ///
    /// It is swept with a line already drawn, because nearly all of it is
    /// absent from an empty one: the points, the figures and the footer that
    /// explains the two map gestures appear only once there is something to
    /// edit.
    @MainActor
    func testTrailMakerPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet"])
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Self.drawnPoints, on: map, in: app)
        XCTAssertTrue(
            element("trail-draft-length", in: app).exists,
            "the audit is worth nothing against a header with no figures on it"
        )

        try audit(app)
    }

    /// And the place sheet, which is a sheet *over* that canvas — so a sweep of
    /// the screen behind it never sees the card a press on the map opens.
    @MainActor
    func testTrailPlaceSheetPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet"])
        let map = element("trail-map", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: UITestTimeout.navigation))

        openTrailMaker(in: app)
        drawTrailPoints(Array(Self.drawnPoints.prefix(2)), on: map, in: app)
        dropPin(at: Self.drawnPoints[2], on: map)
        XCTAssertTrue(
            element("trail-place-sheet", in: app).waitForExistence(
                timeout: UITestTimeout.navigation
            ),
            "a press on the map should open the place sheet"
        )

        try audit(app)
    }

    /// Three presses well inside the map, spread far enough apart that no two
    /// of them land on the same coordinate at any plausible zoom, and high enough
    /// to stay clear of the sheet at every detent — the same offsets
    /// ``TrailMakerUITests`` draws with.
    private static let drawnPoints: [CGVector] = [
        CGVector(dx: 0.45, dy: 0.20),
        CGVector(dx: 0.65, dy: 0.30),
        CGVector(dx: 0.50, dy: 0.42),
    ]
}
