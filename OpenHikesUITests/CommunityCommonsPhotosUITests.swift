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
//  The same scenario seeds the *Community* tab's own *Search this area*,
//  which stands three photographs across the north of the area, and two more
//  beside the east one — see ``SeededCommonsPhotoSource``. The last two cases
//  follow one of them from its pin to its screen and on into the trail maker,
//  and the group of three from its one pin to its grid and to a photograph's
//  screen over it.
//

import XCTest

nonisolated final class CommunityCommonsPhotosUITests: XCTestCase {
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
    func testACommonsPhotographIsShownWithItsAuthorAndLicense() {
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
            app.buttons["Photo by \(SeededCommons.firstAuthor) · \(SeededCommons.license)"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "a Commons photograph should carry its licence, and the way to it, over the picture"
        )
    }

    /// A photograph the tab's search found opens its own screen, credited,
    /// and *Plan a Trail Here* opens the maker with the camera's spot as the
    /// destination and the start still to choose.
    @MainActor
    func testAnAreaPhotographPlansATrailToItself() {
        let app = launchCommunity(scenario: .commons)
        selectCommunityTab(in: app)

        let pin = communityCommonsPhotoPin(in: app)
        XCTAssertTrue(
            pin.waitForExistence(timeout: UITestTimeout.trace),
            "the tab's search should put the area's photographs on the map"
        )
        pin.tap()

        XCTAssertTrue(
            element("commons-photo-screen", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a photo pin should open the photograph's screen"
        )
        XCTAssertTrue(
            element("photo-license-credit", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "and credit who took it, as every Commons photograph is"
        )

        tapWhenReady(element("commons-photo-plan-trail", in: app))
        XCTAssertTrue(
            element("trail-draft-point-1", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "Plan a Trail Here should open the maker with the photograph's spot down"
        )
        XCTAssertTrue(
            element("trail-draft-open-start", in: app).exists,
            "as the destination, with the start left to choose"
        )
    }

    /// Photographs too close together to draw apart are one pin that says
    /// how many it stands for, and it opens them as a grid; a tile opens the
    /// photograph's own screen over the grid, and Back comes back to it.
    @MainActor
    func testAGroupOfAreaPhotographsOpensAsAGrid() {
        let app = launchCommunity(scenario: .commons)
        selectCommunityTab(in: app)

        let group = communityCommonsPhotoGroup(in: app)
        XCTAssertTrue(
            group.waitForExistence(timeout: UITestTimeout.trace),
            "photographs a few metres apart should be drawn as one pin"
        )
        XCTAssertEqual(group.label, "\(SeededCommons.groupCount) photos", "the pin should say how many it stands for")
        group.tap()

        XCTAssertTrue(
            element("commons-photo-group-screen", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a group's pin should open its photographs as a grid"
        )
        for index in 0..<SeededCommons.groupCount {
            XCTAssertTrue(
                element("commons-photo-group-\(index)", in: app).exists,
                "the grid should hold every photograph of the group"
            )
        }
        XCTAssertFalse(
            element("commons-photo-group-\(SeededCommons.groupCount)", in: app).exists,
            "and none the group does not"
        )

        tapWhenReady(element("commons-photo-group-0", in: app))
        XCTAssertTrue(
            element("commons-photo-plan-trail", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "a tile should open the photograph's own screen"
        )
        popScreen(in: app)
        XCTAssertTrue(
            element("commons-photo-group-0", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "Back from the photograph should land on the grid it was opened from"
        )
    }
}
