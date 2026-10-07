//
//  AccessibilityUITests+Share.swift
//  OpenHikesUITests
//
//  The share screens that landed after #662 and that no sweep had seen
//  (#794): a walk's share card, from choosing its photograph to the bar a
//  box's options are on, and the full-screen gallery on the community share
//  form.
//
//  Each was already driven by a functional suite — `WalkUITests+Share`,
//  `CommunityUITests+ShareForm` — which does not run in CI, so each had
//  working automation and nothing that gates a merge. These open them the same
//  way and sweep them.
//
//  What the sweep cannot see is whether a box can be *moved* without a finger:
//  that is the named actions on the box, which `WalkShareStepTests` covers on
//  the host, because no XCUI API lists or performs a custom action.
//
//  Not a second test class, for the reason `AccessibilityUITests+Presented`
//  gives: these are `AccessibilityUITests` methods, they run in the
//  `accessibility-ui-tests` job with the rest, and `--suite
//  AccessibilityUITests` still selects them.
//

import XCTest

extension AccessibilityUITests {
    /// *Share* on a walk's summary: the library button and the hike's own
    /// photographs as a grid of thumbnails.
    @MainActor
    func testWalkSharePhotoChoicePassesAccessibilityAudit() throws {
        let app = launchWalkShare()
        openWalkShare(in: app)

        try audit(app)
    }

    /// The card editor, once with each box's bar up and once with the stats
    /// box's *Figures* menu open over it.
    ///
    /// The route box first, then the stats box: a tap selects whichever box it
    /// lands on, so this order never has to put a bar away to change boxes.
    @MainActor
    func testWalkShareEditorPassesAccessibilityAudit() throws {
        let app = launchWalkShare()
        openWalkShare(in: app)
        let stats = openWalkShareEditor(in: app)
        let controls = element("walk-share-controls", in: app)

        walkShareBox(.route, in: app).tap()
        XCTAssertTrue(
            element("walk-share-line-color", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the route box's bar carries the line's colour"
        )
        try audit(app)

        stats.tap()
        let figures = element("walk-share-figures", in: app)
        XCTAssertTrue(figures.waitForExistence(timeout: UITestTimeout.existence), "the stats box's bar carries Figures")
        XCTAssertTrue(controls.exists)
        try audit(app)

        figures.tap()
        // A menu's toggles are buttons, their state carried as `.isSelected`.
        XCTAssertTrue(
            app.buttons["Distance"].waitForExistence(timeout: UITestTimeout.existence),
            "Figures opens a menu of the figures the box can print"
        )
        try audit(app)
    }

    /// *View Photos* on the community share form: a page per photograph, the
    /// count in the title, the next and previous buttons, and the control that
    /// leaves a picture out.
    @MainActor
    func testCommunityShareGalleryPassesAccessibilityAudit() throws {
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: [
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-photos=3",
            ]
        )
        openHikeDetail(in: app)
        tapWhenReady(element("community-share-button", in: app))
        scrollToTap(element("community-share-view-photos", in: app), in: app)
        XCTAssertTrue(
            app.navigationBars["1 of 3"].waitForExistence(timeout: UITestTimeout.navigation),
            "View Photos should open the gallery at the first photograph"
        )
        XCTAssertTrue(
            element("community-share-photo-toggle", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the audit is worth nothing against a page that has not drawn yet"
        )

        try audit(app)
    }
}
