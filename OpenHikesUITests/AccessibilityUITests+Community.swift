//
//  AccessibilityUITests+Community.swift
//  OpenHikesUITests
//
//  The Community audits that did not fit in the class they belong to, which is
//  at its line limit: the withdrawal form's two, and the review screen's.
//
//  Not a second test class — SwiftLint's `single_test_class` forbids that and
//  it would also have to be added to the list of functional classes
//  `Scripts/run-ui-tests.sh` names. An extension keeps both facts unchanged:
//  these are `AccessibilityUITests` methods, they run in the
//  `accessibility-ui-tests` job with the rest, and `--suite AccessibilityUITests`
//  still selects them.
//
//  The withdrawal pair are here rather than beside the share and report audits
//  because they need a *submitted* hike, which is four taps of setup the other
//  Community audits do not pay — see `shareTheImportedHike(scenario:)`. The
//  review screen's is here only because the class had no room left for it.
//

import XCTest

extension AccessibilityUITests {
    /// The withdrawal form, in the state a hike reaches by being sent.
    ///
    /// The third Community form, and the one the three audits added with the
    /// other two missed — it landed the same day, in the sibling change, so
    /// neither saw the other. ``CommunityWithdrawalSheet``'s own header calls
    /// it ``CommunityReportSheet``'s mirror and deliberately the same screen in
    /// the other direction, and it carries the same things: two
    /// `LabeledContent` rows, a multi-line `TextField`, and a toolbar whose
    /// actions change with the phase.
    ///
    /// It is reached from a **destructive** menu item and from the delete
    /// confirmation's *Ask for Removal First*, so a hiker arrives at it from a
    /// control they may have tapped by mistake — which is the case the audit's
    /// element detection and label checks exist for. Coverage says the same
    /// thing from the other side: the file measures 0.00% in the unit gate's
    /// report, as a SwiftUI view does, which is exactly why the audit is the
    /// only guard it can have.
    ///
    /// Continued from a share rather than seeded, the way
    /// `CommunityUITests.testAWaitingHikeCanAskToBeWithdrawn` is:
    /// `CommunityWithdrawal(hike:)` returns `nil` without a submission id and
    /// the sheet then draws nothing, so the share is what puts a hike in the
    /// state this sweeps.
    @MainActor
    func testCommunityWithdrawalFormPassesAccessibilityAudit() throws {
        let app = shareTheImportedHike(scenario: .seeded)

        tapWhenReady(element("community-share-button", in: app))
        XCTAssertTrue(
            element("community-withdrawal-note", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the audit is worth nothing against a form that has not drawn yet"
        )

        try audit(app)
    }

    /// The same form for a hike a reviewer has published, and the phase only
    /// reachable on a phone with no mail app.
    ///
    /// Two sweeps in one scenario because both need the same setup and neither
    /// is the state above. The footer and the status row are different
    /// sentences for a published hike than for one awaiting review — and that
    /// row is the screen's only `value`, so it is the one element an audit has
    /// something to check that a label check would not.
    ///
    /// The handoff replaces the whole `Form` with a copyable fallback message,
    /// which is a different screen rather than a different state of this one.
    /// A simulator has no mail app, so that is the phase a `mailto:` lands in
    /// here — the one branch of the three this environment can reach, and the
    /// one a hiker with no mail account gets.
    @MainActor
    func testPublishedWithdrawalFormAndFallbackPassAccessibilityAudit() throws {
        let app = shareTheImportedHike(scenario: .published)

        // Back out and in again. `CommunityPublicationCheck` runs from a
        // `.task(id: hike.id)` on the share button, and the id does not change
        // when a submission is written — so the check that turns *awaiting
        // review* into *published* has already run once, against a hike that
        // had no submission yet. Re-entering the screen is what asks it again,
        // and is also what a hiker does.
        popScreen(in: app)
        openHikeDetail(in: app)

        // The menu is what says the promotion landed: a published hike is the
        // only state whose control offers a choice rather than doing one
        // thing.
        tapWhenReady(element("community-share-button", in: app))
        let withdraw = element("community-withdraw-button", in: app)
        XCTAssertTrue(
            withdraw.waitForExistence(timeout: UITestTimeout.existence),
            "a published hike should offer Ask for Removal in a menu"
        )
        tapWhenReady(withdraw)
        XCTAssertTrue(
            element("community-withdrawal-note", in: app)
                .waitForExistence(timeout: UITestTimeout.existence)
        )

        try audit(app)

        tapWhenReady(element("community-withdrawal-send", in: app))
        XCTAssertTrue(
            element("community-withdrawal-fallback-text", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a simulator has no mail app, so the handoff lands in the fallback"
        )

        try audit(app)
    }

    /// Imports the bundled GPX, shares it, and leaves the hike's own screen on
    /// top with a submission against it.
    ///
    /// Shared by the two audits above because it is four taps of setup that
    /// neither is about, and because the share is the only thing in the app
    /// that writes ``Hike/communitySubmissionID``.
    @MainActor
    private func shareTheImportedHike(
        scenario: SeededCommunityScenario
    ) -> XCUIApplication {
        let app = launchCommunity(
            scenario: scenario,
            extraArguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)

        tapWhenReady(element("community-share-button", in: app))
        element("community-author-field", in: app).tap()
        element("community-author-field", in: app).typeText("Ada")
        tapWhenReady(element("community-share-confirm", in: app))
        XCTAssertTrue(
            element("community-share-sent", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the withdrawal form needs a submission to be about"
        )
        app.buttons["Done"].firstMatch.tap()
        return app
    }

    /// The review screen, which is the *other* consequential one.
    ///
    /// Swept for the reason the share form is: this is where a decision is
    /// made that reaches every other user of the app, and it had never been
    /// looked at because it did not exist. The screen is mostly a stranger's
    /// text and photographs at a size chosen to be judged by, which is exactly
    /// the shape an audit has something to say about — and the two decisions
    /// under it are a destructive pair.
    @MainActor
    func testCommunityReviewScreenPassesAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)
        let row = communityRow(titled: SeededQueuedHike.photographedTitle, in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: UITestTimeout.existence),
            "the queue should have drawn before one of its rows is opened"
        )
        row.tap()
        XCTAssertTrue(
            app.staticTexts["Submission"].waitForExistence(timeout: UITestTimeout.existence),
            "the review screen should have drawn before it is swept"
        )

        try audit(app)
    }
}
