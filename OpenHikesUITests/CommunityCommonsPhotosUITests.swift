//
//  CommunityCommonsPhotosUITests.swift
//  OpenHikesUITests
//
//  A route from OpenStreetMap, with the Wikimedia Commons photographs taken
//  along it.
//
//  `--ui-test-community=commons` is ``curated`` plus ``SeededCommonsPhotoSource``,
//  which writes three real JPEGs onto the route the preview downloaded. What is
//  faked is only Wikimedia; the photographs go through the real gallery merge,
//  the real viewer and the real credit. The seeded loop already carries three
//  contributed photographs, so the Commons ones are the fourth to the sixth —
//  which is what makes the merge's numbering something this can see.
//
//  Two things are asserted, and they are the two the licence asks for on the
//  screen: that the strip says where its photographs came from, and that each
//  Commons photograph is shown with who took it and under what licence.
//

import XCTest

nonisolated final class CommunityCommonsPhotosUITests: XCTestCase {
    /// Mirrors ``SeededCommonsPhotoSource``.
    private enum SeededCommons {
        static let firstAuthor = "Anna Berger"
        static let licence = "CC BY-SA 4.0"
        static let count = 3
    }

    /// Contributed first, Commons after, and the strip says whose they are.
    @MainActor
    func testACuratedRouteShowsCommonsPhotographsAfterTheContributedOnes() {
        let app = launchCommunity(scenario: .commons)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededCuratedTrail.loopTitle, in: app)

        XCTAssertTrue(
            communityPhotoStrip(in: app).waitForExistence(timeout: UITestTimeout.trace),
            "a route with photographs along it should draw a strip"
        )
        let attribution = element("community-commons-attribution", in: app)
        XCTAssertTrue(
            attribution.waitForExistence(timeout: UITestTimeout.trace)
                || scrollUntilVisible(attribution, in: app),
            "a strip holding Commons photographs should say where they came from"
        )
    }

    /// The fourth photograph is the first from Commons: its page is titled
    /// with its author and carries the licence it was shared under.
    @MainActor
    func testACommonsPhotographIsShownWithItsAuthorAndLicence() {
        let app = launchCommunity(scenario: .commons)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededCuratedTrail.loopTitle, in: app)

        tapWhenReady(communityPhotoTile(at: 0, in: app), timeout: UITestTimeout.trace)
        XCTAssertTrue(
            element("community-photo-viewer", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "tapping a photograph should open the gallery"
        )
        let next = app.buttons["Next photo"]
        for _ in 0..<SeededContribution.photoCount {
            tapWhenReady(next)
        }

        let total = SeededContribution.photoCount + SeededCommons.count
        let page = SeededContribution.photoCount + 1
        XCTAssertTrue(
            app.navigationBars["\(page) of \(total) · by \(SeededCommons.firstAuthor)"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "the first Commons photograph should come after the contributed ones, credited to its author"
        )
        XCTAssertTrue(
            app.buttons["Photo by \(SeededCommons.firstAuthor) · \(SeededCommons.licence)"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "a Commons photograph should carry its licence, and the way to it, over the picture"
        )
    }
}
