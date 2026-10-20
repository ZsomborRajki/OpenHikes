//
//  AccessibilityUITests+Commons.swift
//  OpenHikesUITests
//
//  The two places a Wikimedia Commons photograph is drawn on a route from
//  OpenStreetMap: the preview's strip with the sentence under it, and the
//  gallery page with its credit over the picture. And the screen a photograph
//  the *Community* tab's search found opens: the picture, its credit, the
//  place and *Plan a Trail Here* — and the grid a group of them opens.
//
//  An extension of `AccessibilityUITests` rather than a class of its own, for
//  the reason `AccessibilityUITests+Community.swift` gives: `single_test_class`
//  forbids a second, and these are that class's methods, run in the
//  `accessibility-ui-tests` job with the rest.
//

import XCTest

extension AccessibilityUITests {
    /// Both screens in one scenario, because both need the same setup: the
    /// `commons` scenario, a curated route opened, and its photographs landed.
    ///
    /// The credit is the one new *control* here — a menu whose two items open
    /// the photograph's page and its licence — so it is what the hit-region
    /// and description checks have something to say about.
    @MainActor
    func testCommonsPhotosPassAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .commons)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededCuratedTrail.loopTitle, in: app)
        let attribution = element("community-commons-attribution", in: app)
        XCTAssertTrue(
            attribution.waitForExistence(timeout: UITestTimeout.trace)
                || scrollUntilVisible(attribution, in: app),
            "the audit is worth nothing against a strip whose Commons photographs have not landed"
        )
        try audit(app)

        // The fourth page is the first from Commons — the curated loop's three
        // contributed photographs come before it.
        tapWhenReady(communityPhotoTile(at: 0, in: app), timeout: UITestTimeout.trace)
        let next = app.buttons["Next photo"]
        for _ in 0..<SeededContribution.photoCount {
            tapWhenReady(next)
        }
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo by'")).firstMatch
                .waitForExistence(timeout: UITestTimeout.existence),
            "the gallery should be on a Commons photograph, with its credit drawn, before it is swept"
        )
        try audit(app)
    }

    /// The photograph screen a *Community* pin opens. Its row of three
    /// buttons shares the width with the longest word here, *Plan a Trail
    /// Here*, which is what the clipped-text check has something to say about.
    @MainActor
    func testCommonsPhotoScreenPassesAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .commons)
        selectCommunityTab(in: app)
        tapWhenReady(communityCommonsPhotoPin(in: app), timeout: UITestTimeout.trace)
        XCTAssertTrue(
            element("commons-photo-plan-trail", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the audit is worth nothing before the photograph's screen is up"
        )
        try audit(app)
    }

    /// The grid a group of those pins opens. Its tiles are pictures and
    /// nothing else, so each has to carry its own name — the credit and the
    /// date — which is what the description check has something to say about.
    @MainActor
    func testCommonsPhotoGroupPassesAccessibilityAudit() throws {
        let app = launchCommunity(scenario: .commons)
        selectCommunityTab(in: app)
        tapWhenReady(communityCommonsPhotoGroup(in: app), timeout: UITestTimeout.trace)
        XCTAssertTrue(
            element("commons-photo-group-0", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "the audit is worth nothing before the group's grid is up"
        )
        try audit(app)
    }
}
