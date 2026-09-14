//
//  CommunityUITests.swift
//  OpenHikesUITests
//
//  The feature that shipped without a single test walking through it.
//
//  ``OpenHikesModel/makeCommunityTransport()`` hands back `nil` for any launch
//  that is running tests, which takes the picker, the list, the preview and
//  the share button with it — so every class in this bundle could pass while
//  Community sat behind a door none of them could open, and that is exactly
//  what was happening.
//
//  What made that hard to fix is that there is no sandbox for the public
//  database: a submission made from a test is a submission, in the developer's
//  own container, in a reviewer's queue. `--ui-test-community=<scenario>` is
//  the way through — it selects ``SeededCommunityTransport``, a debug-only
//  stand-in, and *only* when a scenario names it. Everything below the
//  transport is the shipping app: the browser spends its real page budget,
//  the preview validates the route the way it validates a stranger's, the
//  photographs are real JPEGs through the real decode, and an import writes to
//  the real store.
//
//  Every scenario puts a simulated fix on the fixture trailhead. The seeded
//  hikes start there, so a nearby search from there answers with all three,
//  and the map has a region to be asked about at all — a browse with no region
//  sits on a spinner, which is a state worth nothing to assert against.
//

import CoreLocation
import XCTest

nonisolated final class CommunityUITests: XCTestCase {
    // MARK: - Finding the list

    /// The tab exists, it is reachable, and selecting it asks the database
    /// something.
    ///
    /// The first thing worth proving, and it was untestable until now: the
    /// picker is drawn only when the launch has a transport, so its presence
    /// is the whole of what `--ui-test-community=` buys.
    @MainActor
    func testCommunityTabListsPublishedHikes() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)

        for title in SeededHike.allTitles {
            XCTAssertTrue(
                communityRow(titled: title, in: app)
                    .waitForExistence(timeout: UITestTimeout.existence),
                "\"\(title)\" should be listed once the Community tab is selected"
            )
        }
    }

    /// The tab is absent entirely without the argument, which is the guarantee
    /// the stub had to be added without breaking: a launch that does not ask
    /// for a stand-in database gets no transport, and a launch with no
    /// transport cannot reach a shared database by any gesture.
    @MainActor
    func testCommunityIsAbsentWithoutASeededDatabase() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet"])

        // The segment rather than the picker's identifier, because the
        // segment is the thing a hiker could tap. A control that is absent
        // from the screen and a control whose container is merely not exposed
        // to the accessibility tree are the same assertion otherwise, and only
        // one of them is the guarantee being made.
        XCTAssertFalse(
            app.buttons["Community"].waitForExistence(timeout: UITestTimeout.navigation),
            "an ordinary UI-test launch must not be able to select Community at all"
        )
        XCTAssertTrue(
            app.staticTexts["Hikes"].exists,
            "a launch with no transport shows the old heading in the picker's place"
        )
    }

    /// What the list says when the answer is nothing, which is the ordinary
    /// answer for most of the world.
    @MainActor
    func testAnEmptyAreaSaysSoRatherThanShowingNothing() {
        let app = launchCommunity(scenario: .empty)
        selectCommunityTab(in: app)

        XCTAssertTrue(
            element("community-nearby-empty", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "an area with nothing published should say so"
        )
    }

    /// A read that fails says which failure it was and offers the retry, and
    /// the retry is a real control rather than a sentence about one.
    @MainActor
    func testAFailedSearchOffersTheRetry() {
        let app = launchCommunity(scenario: .failing)
        selectCommunityTab(in: app)

        let empty = element("community-nearby-empty", in: app)
        XCTAssertTrue(
            empty.waitForExistence(timeout: UITestTimeout.existence),
            "a failed search should report itself where the rows would be"
        )
        // Waited for through `awaitCommunityAnswer`, because the *retry* is
        // the half of this screen that only exists once a search has actually
        // been asked for. The row above is drawn before then too — an idle
        // browser and a browser that has just failed both put something where
        // the rows would be — so a machine slow enough that the map settles
        // twice leaves this test asserting against a state nobody reached.
        XCTAssertTrue(
            awaitCommunityAnswer(app.buttons["Try Again"], in: app),
            "a failure the hiker can do nothing about is a failure with a retry"
        )
    }

    // MARK: - Opening one

    /// The preview: the page a hiker decides on, off a route this process
    /// downloaded and validated rather than one a fixture handed it.
    @MainActor
    func testOpeningAPublishedHikeShowsItsPageAndPhotographs() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        XCTAssertTrue(
            element("community-import-button", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a loaded preview offers to add the hike"
        )
        XCTAssertTrue(
            communityPhotoStrip(in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the preview should show the photographs it downloaded"
        )
    }

    /// Adding somebody else's hike to the library, with its photographs.
    ///
    /// The import is the one gesture here that writes something the hiker
    /// keeps, so the assertions are made on what they kept rather than on the
    /// preview: a button that changed its title proves nothing about what was
    /// saved. Importing pops straight to the new hike's own detail screen —
    /// ``MapSheet/openImported(_:from:)`` replaces the path rather than
    /// pushing — so the first thing to see is that screen, and the second is
    /// that a stranger's photographs are now in this hiker's gallery.
    @MainActor
    func testImportingAPublishedHikeAddsItToTheLibrary() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        tapWhenReady(element("community-import-button", in: app))

        XCTAssertTrue(
            app.navigationBars[SeededHike.ridgeTitle]
                .waitForExistence(timeout: UITestTimeout.existence),
            "importing should open the hike it just saved"
        )
        XCTAssertTrue(
            photoTile(at: 1, of: SeededHike.ridgePhotoCount, in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the imported hike should carry the photographs that came with it"
        )

        // And it is in the library rather than merely on screen. Backing out
        // lands on the sheet with the Community tab still selected — importing
        // a hike is not a decision to stop browsing — so the hiker's own list
        // has to be asked for before their own hike can be in it.
        popScreen(in: app)
        selectMyHikesTab(in: app)
        awaitHikeRow(titled: SeededHike.ridgeTitle, in: app)
    }

    /// Item 6 of the release review, from the outside.
    ///
    /// Backing out of a preview and opening the same listing again used to
    /// share one download directory between the two visits, so the first
    /// visit's cleanup could delete the second visit's photographs. The
    /// directory is per-visit now; what that has to look like from here is a
    /// reopened preview with its pictures still on it.
    @MainActor
    func testReopeningTheSamePreviewKeepsItsPhotographs() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)

        for _ in 0..<2 {
            openCommunityHike(titled: SeededHike.ridgeTitle, in: app)
            XCTAssertTrue(
                communityPhotoStrip(in: app).waitForExistence(timeout: UITestTimeout.existence),
                "a reopened preview should still have its photographs"
            )
            popScreen(in: app)
        }
    }

    // MARK: - Moderation

    /// Guideline 1.2's two gestures, and the half that changes what the hiker
    /// sees. Anna published two of the three seeded hikes, so blocking her has
    /// to take two rows and leave one — a list that emptied would be
    /// indistinguishable from a list that broke.
    @MainActor
    func testBlockingAnAuthorHidesEveryHikeTheyPublished() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        tapWhenReady(element("community-moderation-menu", in: app))
        tapWhenReady(element("community-block-button", in: app))
        tapWhenReady(element("community-block-confirm", in: app))

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) {
                !communityRow(titled: SeededHike.ridgeTitle, in: app).exists
                    && !communityRow(titled: SeededHike.scrambleTitle, in: app).exists
            },
            "blocking an author should take every hike they published"
        )
        XCTAssertTrue(
            communityRow(titled: SeededHike.lakeTitle, in: app).exists,
            "blocking one author must not empty the list"
        )
    }

    /// The report sheet opens and asks its question. Sending is deliberately
    /// not driven: the handoff is a system mail composer, which is another
    /// process, and what this screen owes the hiker is that the form is there
    /// and reachable from the hike it is about.
    @MainActor
    func testReportingAHikeOpensTheForm() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        tapWhenReady(element("community-moderation-menu", in: app))
        tapWhenReady(element("community-report-button", in: app))

        XCTAssertTrue(
            element("community-report-reason", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the report form should ask what is wrong with the hike"
        )
    }

    // MARK: - Publishing

    /// The other direction, and the one that was free but unreachable: a hike
    /// of the hiker's own, offered to the community and accepted.
    @MainActor
    func testSharingAHikePublishesItForReview() {
        let app = launchCommunity(
            scenario: .seeded,
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
            "a submitted hike should say it is waiting for review"
        )
    }

    /// The one place in this app a hiker can write about a walk.
    ///
    /// `Hike.trackDescription` had three sources before this and no screen
    /// that could fill any of them — a GPX file's `<desc>`, a hike imported
    /// from one, and a hike saved from somebody else's listing — so every walk
    /// recorded on a phone reached a reviewer with "Nothing written." against
    /// it. The fixture GPX carries no description, which is what makes this
    /// assertion mean something: the box starts empty, and what comes back is
    /// what was typed.
    ///
    /// Asserted across a close and a reopen rather than on the field itself,
    /// because what is worth proving is that the notes reached the *hike*. A
    /// value read straight back out of a text field would prove only that the
    /// keyboard works.
    @MainActor
    func testNotesTypedOnTheShareSheetStayWithTheHike() {
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)
        let notes = "Boggy after the second bridge. Good bench at the top."

        tapWhenReady(element("community-share-button", in: app))
        let field = element("community-share-notes", in: app)
        XCTAssertTrue(
            field.waitForExistence(timeout: UITestTimeout.existence),
            "the share sheet should ask for notes"
        )
        field.tap()
        field.typeText(notes)
        // Cancelled rather than shared: the notes belong to the walk, so
        // thinking better of publishing must not throw away what was written.
        app.buttons["Cancel"].firstMatch.tap()

        tapWhenReady(element("community-share-button", in: app))
        let reopened = element("community-share-notes", in: app)
        XCTAssertTrue(
            reopened.waitForExistence(timeout: UITestTimeout.existence),
            "the share sheet should have come back"
        )
        XCTAssertEqual(
            reopened.value as? String,
            notes,
            "what was typed should have landed on the hike rather than on the sheet"
        )
    }

    /// The state that used to be a dead end.
    ///
    /// A hike waiting for review was a disabled glyph with nothing to do,
    /// while `docs/privacy` and `docs/terms` both promised the hiker could ask
    /// for it back. Continues from the share above rather than seeding a
    /// submitted hike, because the share is what puts one in that state — and
    /// this way the test asserts the transition and not a fixture.
    @MainActor
    func testAWaitingHikeCanAskToBeWithdrawn() {
        let app = launchCommunity(
            scenario: .seeded,
            extraArguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)

        tapWhenReady(element("community-share-button", in: app))
        element("community-author-field", in: app).tap()
        element("community-author-field", in: app).typeText("Ada")
        tapWhenReady(element("community-share-confirm", in: app))
        XCTAssertTrue(
            element("community-share-sent", in: app)
                .waitForExistence(timeout: UITestTimeout.existence)
        )
        app.buttons["Done"].firstMatch.tap()

        tapWhenReady(element("community-share-button", in: app))
        XCTAssertTrue(
            element("community-withdrawal-note", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a hike waiting for review should offer a way to ask for it back"
        )
        // The record names are the whole point: they live on the `Hike` row
        // and nowhere else, so this screen is the last place to read them.
        tapWhenReady(element("community-withdrawal-send", in: app))
        let message = element("community-withdrawal-fallback-text", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(
            (message.label + (message.value as? String ?? ""))
                .contains("CommunityHikeSubmission:"),
            "the request has to name the submission a reviewer would delete"
        )
    }
}
