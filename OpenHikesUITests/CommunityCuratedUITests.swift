//
//  CommunityCuratedUITests.swift
//  OpenHikesUITests
//
//  The mixed list, which is the one the shipping app draws.
//
//  ``SeededCuratedTrailSource`` and `--ui-test-community=curated` were built
//  with this class's argument written into them and no class to make it:
//  everything the two row kinds differ in is invisible unless both are on
//  screen at once. A run against `.seeded` sees a list where every row has an
//  author, every menu has three items in it and nothing on the page mentions
//  OpenStreetMap — so it can pass in full while the curated half is broken in
//  any way at all.
//
//  What is faked is only the network. These rows go through the real
//  ``CuratedTrailFacts`` parser, the real
//  ``CommunityListing/init(curated:editedAt:)``, the real
//  ``MergedCommunityTransport`` merge and limit split, and the real preview —
//  so a case that opens one is testing the app.
//
//  Four things are asserted, and they are the ones nothing else can reach:
//
//  - **Both halves in one list**, which is what the merge is for. A published
//    hike never loses its place to a curated one, so the three seeded hikes
//    have to still be there beside the two routes.
//  - **The row says which kind it is in words.** The glyph differs too — a
//    signpost rather than a walker — but it is `accessibilityHidden` like
//    every other decoration in that row, so what a screen reader gets is the
//    subtitle, and the subtitle is what this reads.
//  - **The ODbL credit is conditional**, which is what makes it a credit
//    rather than boilerplate. Both directions, because either alone would pass
//    against a footer that was always there or never.
//  - **Report and Block are absent rather than disabled.** That is the whole
//    of the Guideline 1.2 argument: an OSM relation is not user-generated
//    content, there is nobody to block, and the old fallback title read *Block
//    This Hiker* about nobody. A published hike opened in the same launch
//    still has both, which is what makes the absence a statement about the
//    source rather than about a gesture that missed.
//

import XCTest

nonisolated final class CommunityCuratedUITests: XCTestCase {
    // MARK: - One list, two sources

    /// The published hikes and the OpenStreetMap routes are in the same list,
    /// and the published ones did not lose their place.
    ///
    /// The limit is spent on CloudKit first — see ``MergedCommunityTransport``
    /// — so a merge that let the curated half answer *instead of* the
    /// published one rather than beside it fails here rather than somewhere
    /// downstream.
    @MainActor
    func testTheListHoldsBothKindsAtOnce() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)

        for title in SeededHike.allTitles + SeededCuratedTrail.allTitles {
            let row = communityRow(titled: title, in: app)
            XCTAssertTrue(
                awaitCommunityAnswer(row, in: app),
                "\"\(title)\" should be listed once both halves have answered"
            )
        }
    }

    /// The credit ODbL requires is under the list, and only because a curated
    /// row is in it.
    ///
    /// Two launches in one case, the way ``CommunityReviewUITests`` compares a
    /// reviewer's list against an ordinary one: the assertion is about the
    /// *difference* between two databases behind one screen, and there is no
    /// gesture that changes which one a launch got.
    @MainActor
    func testTheListCreditsOpenStreetMapOnlyWhenItIsShowingIt() {
        let curated = launchCommunity(scenario: .curated)
        selectCommunityTab(in: curated)
        XCTAssertTrue(
            awaitCommunityAnswer(
                communityRow(titled: SeededCuratedTrail.loopTitle, in: curated),
                in: curated
            ),
            "the curated half should have answered before its footer is asserted about"
        )
        XCTAssertTrue(
            isOnScreen("community-osm-credit", in: curated),
            "a list holding OpenStreetMap routes must credit its contributors"
        )

        let published = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: published)
        XCTAssertTrue(
            awaitCommunityAnswer(
                communityRow(titled: SeededHike.ridgeTitle, in: published),
                in: published
            ),
            "the seeded list should answer before its footer is asserted about"
        )
        XCTAssertFalse(
            isOnScreen("community-osm-credit", in: published),
            "a list of hikes people published owes OpenStreetMap no credit"
        )
    }

    // MARK: - What the row says

    /// A curated row spends its subtitle on the two facts a hiker decides on,
    /// and a published row still spends its on the person who walked it.
    ///
    /// Both directions in one launch, because either alone would pass against
    /// a row that drew every part for every listing.
    @MainActor
    func testACuratedRowSaysWhatTheSignpostSays() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)

        let loop = communityRow(titled: SeededCuratedTrail.loopTitle, in: app)
        XCTAssertTrue(
            awaitCommunityAnswer(loop, in: app),
            "\"\(SeededCuratedTrail.loopTitle)\" should be listed"
        )
        let label = loop.label
        XCTAssertTrue(
            label.contains(SeededCuratedTrail.loopShape),
            "a curated row should say whether the walk ends back at the car: \(label)"
        )
        XCTAssertTrue(
            label.contains(SeededCuratedTrail.loopWaymark),
            "a curated row should say what to follow on the ground: \(label)"
        )
        XCTAssertFalse(
            label.contains("by "),
            "nobody published this route, so there is nobody to credit: \(label)"
        )

        let published = communityRow(titled: SeededHike.ridgeTitle, in: app)
        XCTAssertTrue(
            awaitCommunityAnswer(published, in: app),
            "\"\(SeededHike.ridgeTitle)\" should be listed beside it"
        )
        XCTAssertTrue(
            published.label.contains("by "),
            "a published hike still credits the hiker who shared it: \(published.label)"
        )
    }

    // MARK: - The profile OpenStreetMap cannot supply

    /// A curated route draws an elevation chart, and credits whoever the
    /// heights came from.
    ///
    /// OpenStreetMap carries no `ele` on a hiking relation — zero of 1,725
    /// nodes, measured — so until the heights were fetched this screen drew no
    /// chart at all, which is the whole of #428. The seeded source answers the
    /// way the real one does, through the real
    /// ``CuratedElevationSourcing/filled(_:)`` and the real `RouteProfile`, so
    /// what this proves is the wiring rather than the fixture.
    ///
    /// The credit is asserted beside it because it is owed *by* the chart: a
    /// profile drawn with no sentence under it is a vendor used and not named.
    @MainActor
    func testACuratedRouteDrawsAProfileAndSaysWhereItCameFrom() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededCuratedTrail.loopTitle, in: app)

        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(
            scrollUntilVisible(chart, in: app),
            "a curated route should draw the profile its heights were fetched for"
        )
        let credit = element("community-elevation-attribution", in: app)
        XCTAssertTrue(
            scrollUntilVisible(credit, in: app),
            "the heights are not OpenStreetMap's, so the screen has to say whose they are"
        )
    }

    /// And a published hike's chart carries no such line: those heights came
    /// from the hiker who walked it.
    @MainActor
    func testAPublishedHikeCreditsNobodyForItsHeights() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        XCTAssertTrue(
            scrollUntilVisible(element("elevation-chart", in: app), in: app),
            "precondition: the published hike draws a chart of its own"
        )
        XCTAssertFalse(
            element("community-elevation-attribution", in: app).exists,
            "nobody was asked for these heights, so nobody is credited for them"
        )
    }

    // MARK: - What the screen offers, and what it does not

    /// Opening a curated route says where the data came from, with a link, and
    /// offers nothing to report or block.
    ///
    /// The import item is asserted *first* and is doing real work: it is what
    /// proves the menu opened at all, so the two absences after it are about
    /// the listing rather than about a tap that missed.
    @MainActor
    func testACuratedRouteHasNobodyToReportOrBlock() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededCuratedTrail.loopTitle, in: app)

        XCTAssertTrue(
            isOnScreen("community-trail-facts", in: app),
            "a fully tagged route should draw the On the Trail section"
        )
        XCTAssertTrue(
            isOnScreen("community-osm-attribution", in: app),
            "the screen a curated route opens must credit OpenStreetMap with a link"
        )

        openActionsMenu(in: app)
        XCTAssertTrue(
            element("community-import-menu-button", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "the menu should have opened, and saving a curated route is offered"
        )
        XCTAssertFalse(
            element("community-report-button", in: app).exists,
            "there is no record for a reviewer to delete, so Report is not offered"
        )
        XCTAssertFalse(
            element("community-block-button", in: app).exists,
            "there is no author, so Block is not offered about nobody"
        )
    }

    /// The same menu on a published hike has both, which is what makes the
    /// absences above a statement about the source rather than about the menu.
    @MainActor
    func testAPublishedHikeStillOffersReportAndBlock() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        openActionsMenu(in: app)
        XCTAssertTrue(
            element("community-report-button", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "a hike somebody published can be reported"
        )
        XCTAssertTrue(
            element("community-block-button", in: app).exists,
            "a hike somebody published has an author to block"
        )
    }
}

// MARK: - Gestures these cases share

private extension CommunityCuratedUITests {
    /// Opens the preview's *Add, report or block* menu.
    @MainActor
    func openActionsMenu(in app: XCUIApplication) {
        let menu = element("community-actions-menu", in: app)
        XCTAssertTrue(
            menu.waitForExistence(timeout: UITestTimeout.existence),
            "the actions menu should be offered whichever source the hike came from"
        )
        menu.tap()
    }

    /// Whether `identifier` is anywhere on the screen, scrolling to look.
    ///
    /// `exists` rather than ``XCTestCase/isReachable(_:in:)``, and the
    /// difference matters here: both things this is asked about are section
    /// *containers* — a `VStack` carrying an identifier, with the words inside
    /// it — and what the case is about is whether the section is on the page
    /// at all, not whether a container is hittable. The scroll is still
    /// needed, because a section below the fold of a `List` or a `ScrollView`
    /// may not be in the element tree until something has scrolled to it.
    @MainActor
    func isOnScreen(_ identifier: String, in app: XCUIApplication) -> Bool {
        let target = element(identifier, in: app)
        if target.waitForExistence(timeout: UITestTimeout.navigation) { return true }
        scrollUntilVisible(target, in: app)
        return target.exists
    }
}
