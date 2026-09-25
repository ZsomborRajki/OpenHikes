//
//  CommunityReviewUITests.swift
//  OpenHikesUITests
//
//  The reviewer's half of the Community tab, driven end to end.
//
//  Its own class rather than more of `CommunityUITests`, for the reason that
//  file's scenarios are split the way they are: what is here is a different
//  database shape — a queue in front of the browse list — and a different
//  person using it. Everything in the other class is a hiker looking at hikes.
//
//  **What these cannot prove, and it is the important one.** In production the
//  review section is absent because the *server* refuses the queue read, and
//  no launch argument can stand in for that: `--ui-test-community=reviewing`
//  is the scenario pretending to be in the role. So the case worth asserting
//  here is the negative — every other scenario's queue is refused, exactly as
//  a real account outside the role is refused — and the positive case is a
//  test of the screens rather than of the permission. The permission is
//  `CommunitySchema`'s, and the only thing that can check it is a signed build
//  against a live container.
//

import XCTest

nonisolated final class CommunityReviewUITests: XCTestCase {
    /// The queue is above the published list, and the two are separate lists
    /// of separate things.
    @MainActor
    func testTheReviewSectionListsWhatIsWaiting() {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)

        for title in SeededQueuedHike.allTitles {
            XCTAssertTrue(
                communityRow(titled: title, in: app)
                    .waitForExistence(timeout: UITestTimeout.existence),
                "\"\(title)\" should be waiting in the review section"
            )
        }
        // Swept for rather than waited on, and a longer wait is demonstrably
        // not the same thing: with the queue and its header above it, the
        // first published row sits past the fold of a sheet that shows four,
        // and `List` does not build a row it has not been scrolled to. A
        // fifteen-second `waitForExistence` here fails exactly as `.exists`
        // did — the browser had answered, and the answer was not in the
        // element tree. ``awaitCommunityAnswer(_:in:)`` is where that argument
        // lives, and it is how every other scenario reaches a published row.
        XCTAssertTrue(
            awaitCommunityAnswer(
                communityRow(titled: SeededHike.ridgeTitle, in: app),
                in: app
            ),
            "the published hikes should still be listed under it"
        )
    }

    /// The negative, and the one that stands in for the production guarantee:
    /// a launch whose queue is refused draws no section at all. Every scenario
    /// but `reviewing` refuses it, which is what a real account outside the
    /// `reviewer` role gets.
    @MainActor
    func testAnOrdinaryLaunchHasNoReviewSection() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)

        XCTAssertTrue(
            communityRow(titled: SeededHike.ridgeTitle, in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the published list should have drawn before the absence below means anything"
        )
        XCTAssertFalse(
            element("community-review-section", in: app).exists,
            "a hiker whose queue was refused should see no review section"
        )
        for title in SeededQueuedHike.allTitles {
            XCTAssertFalse(
                communityRow(titled: title, in: app).exists,
                "\"\(title)\" is queued, not published, and must not be listed"
            )
        }
    }

    /// The section has to survive the hiker looking at their own hikes.
    ///
    /// It did not: leaving the tab emptied the queue and coming back declined
    /// to ask for it again, because the launch had already spent its one
    /// question — so the *Pending Review* section vanished on the first trip to
    /// *My Hikes* and did not return until the app was relaunched. Two rules
    /// that each had a passing test, and a feature that was usable once per
    /// launch between them.
    ///
    /// Asserted through the segments rather than on the queue object, because
    /// that is where it was found and neither unit test could see it: each one
    /// was about a single rule.
    @MainActor
    func testTheReviewSectionSurvivesATripToMyHikes() {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)
        let queued = communityRow(titled: SeededQueuedHike.title, in: app)
        XCTAssertTrue(
            queued.waitForExistence(timeout: UITestTimeout.existence),
            "the queue should have drawn before it can be left"
        )

        app.buttons["My Hikes"].tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { !queued.exists },
            "the community list should have gone with the segment"
        )
        selectCommunityTab(in: app)

        XCTAssertTrue(
            queued.waitForExistence(timeout: UITestTimeout.existence),
            "and the review section should come back with it"
        )
        XCTAssertTrue(
            element("community-review-section", in: app).exists,
            "header included, not just the row"
        )
    }

    /// What a reviewer is actually deciding about: the hiker's own words and
    /// their photographs, at a size worth looking at.
    @MainActor
    func testOpeningAQueuedSubmissionShowsWhatIsBeingDecided() {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)
        openQueuedSubmission(titled: SeededQueuedHike.photographedTitle, in: app)

        // `scrollUntilVisible` rather than `scrollIntoView`, for the reason its
        // own summary gives: the photographs arrive after a download, so the
        // section can appear *above* where a one-way search has already
        // scrolled to. This screen is a sheet, and both sections are below its
        // fold at the detent it opens on.
        XCTAssertTrue(
            scrollUntilVisible(reviewPhotoHeading(in: app), in: app),
            "the review screen should show the photographs it downloaded"
        )
        XCTAssertTrue(
            scrollUntilVisible(element("review-decline", in: app), in: app),
            "and offer the other decision beside publishing"
        )
    }

    /// Publishing takes the row away without asking the server again, because
    /// the decision has already landed — see `CommunityReviewQueue.forget(_:)`.
    /// A reviewer left looking at a hike they have just dealt with is the state
    /// that invites doing it twice.
    @MainActor
    func testPublishingTakesTheSubmissionOutOfTheQueue() {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)
        openQueuedSubmission(titled: SeededQueuedHike.title, in: app)

        let publish = element("review-publish", in: app)
        XCTAssertTrue(
            scrollUntilVisible(publish, in: app),
            "the decision is at the foot of the screen, under what it is about"
        )
        // Enabled only once the submission has loaded, which is not a detail
        // of the test: the photo count that goes onto the listing arrives with
        // the photographs, and a reviewer publishing before them would be
        // approving a title. See `CommunityReviewDecisions.hasLoaded`.
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { publish.isEnabled },
            "publishing should wait for what is being decided about"
        )
        publish.tap()

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) {
                !communityRow(titled: SeededQueuedHike.title, in: app).exists
            },
            "a published submission should leave the queue"
        )
        XCTAssertTrue(
            communityRow(titled: SeededQueuedHike.photographedTitle, in: app).exists,
            "and take nothing else with it"
        )
    }

    /// The takedown is offered on a *published* hike, which has no queue row —
    /// so the only thing that can decide whether to draw it is whether the
    /// server let this account read the queue at all. That is why
    /// `CommunityReviewQueue.isReviewer` is a separate answer from an empty
    /// list.
    @MainActor
    func testTakeDownIsOfferedToAReviewerAndNobodyElse() {
        let reviewing = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: reviewing)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: reviewing)
        element("community-actions-menu", in: reviewing).tap()
        XCTAssertTrue(
            element("community-take-down-button", in: reviewing)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a reviewer should be able to unlist a published hike"
        )
        reviewing.terminate()

        let browsing = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: browsing)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: browsing)
        element("community-actions-menu", in: browsing).tap()
        XCTAssertTrue(
            element("community-report-button", in: browsing)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the menu should have opened before the absence below means anything"
        )
        XCTAssertFalse(
            element("community-take-down-button", in: browsing).exists,
            "an ordinary hiker must not be offered a control that can only fail"
        )
    }

    /// The title a reviewer publishes under is theirs to correct, and the one
    /// that was sent stays in front of them while they do it.
    ///
    /// The submission is never touched by this — only the listing carries the
    /// edited name — but nothing a UI test can see says so, which is what the
    /// unit suites and `CommunitySchema`'s permissions are for. What is
    /// checkable here is that the field is a field, that it takes an edit, and
    /// that the original is still readable afterwards.
    @MainActor
    func testAReviewerCanCorrectTheTitleBeforePublishing() {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)
        openQueuedSubmission(titled: SeededQueuedHike.title, in: app)

        let field = element("review-title-field", in: app)
        XCTAssertTrue(
            scrollUntilVisible(field, in: app),
            "the title should be editable on the screen that decides about it"
        )
        field.tap()
        // Cleared a character at a time rather than through the edit menu:
        // what a reviewer does to a title like "Morning walk" is replace it,
        // and a long press racing a callout menu is a flake this assertion
        // does not need.
        field.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: SeededQueuedHike.title.count)
        )
        field.typeText("Karwendelhaus, by the north side")
        // The keyboard goes before anything below it is asked for, and that
        // is the gesture rather than a tidy-up. It covers what the sheet has
        // left at its resting height, so a swipe meant to scroll starts
        // inside it, and `review-publish` sits in a `Form`, which does not
        // build a row until something scrolls to it. The runs that found this
        // failed at exactly those two points: one on a *Publish* that was
        // there and covered, one on a *Publish* that was never built.
        commitKeyboardEdit(in: app)

        XCTAssertTrue(
            element("review-original-title", in: app).waitForExistence(timeout: UITestTimeout.existence),
            "what the hiker sent should still be readable beside the correction"
        )
        let publish = element("review-publish", in: app)
        XCTAssertTrue(scrollUntilVisible(publish, in: app), "the decision should still be reachable")
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) { publish.isEnabled },
            "a titled submission should be publishable"
        )
    }

    /// One bad photograph should cost that photograph, not the hike.
    ///
    /// Before this, a reviewer looking at a good walk with one picture that
    /// could not be published had two options, and both were wrong: publish it
    /// anyway, or decline — which deletes the hiker's whole upload and never
    /// tells them. The heading is what a test can see, because the tiles
    /// themselves are `accessibilityHidden`; it counts what is still going.
    @MainActor
    func testAReviewerCanLeaveOnePhotoOut() {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)
        openQueuedSubmission(titled: SeededQueuedHike.photographedTitle, in: app)

        let heading = reviewPhotoHeading(in: app)
        XCTAssertTrue(
            scrollUntilVisible(heading, in: app),
            "the photographs should have arrived before any of them can be left out"
        )
        XCTAssertEqual(
            heading.label,
            "Photos (\(SeededQueuedHike.photoCount))",
            "the heading should start by counting them all"
        )

        element("review-photo-remove", in: app).firstMatch.tap()

        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) {
                heading.label == "Photos (\(SeededQueuedHike.photoCount - 1) of \(SeededQueuedHike.photoCount))"
            },
            "the heading should say how many are still going, and out of how many"
        )
        // Reversible for as long as the decision is: nothing has left the
        // submission until Publish, so the tile is still there to put back.
        element("review-photo-restore", in: app).firstMatch.tap()
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) {
                heading.label == "Photos (\(SeededQueuedHike.photoCount))"
            },
            "putting it back should restore the count"
        )
    }

    /// The row that told a reviewer to look at the map is gone, and the map is
    /// still drawing the route.
    ///
    /// It said "Drawn on the map behind this sheet." under a *Route* heading,
    /// which is a row spent telling somebody to look at the thing they are
    /// already looking at. What replaces it is nothing — the line itself,
    /// which was always the point.
    @MainActor
    func testTheRouteSectionIsGoneAndTheLineIsNot() {
        let app = launchCommunity(scenario: .reviewing)
        selectCommunityTab(in: app)
        openQueuedSubmission(titled: SeededQueuedHike.title, in: app)

        XCTAssertTrue(
            scrollUntilVisible(element("review-decline", in: app), in: app),
            "the whole screen should have been walked before the absence below means anything"
        )
        XCTAssertFalse(
            app.staticTexts["Drawn on the map behind this sheet."].exists,
            "the route row should be gone"
        )
        XCTAssertFalse(
            element("review-route-undrawable", in: app).exists,
            "and a seeded submission's route is long enough to draw, so the fallback is absent too"
        )
    }

    /// The review screen's Photos heading, which carries the count.
    ///
    /// Matched on the prefix rather than spelled out, for the reason
    /// `communityPhotoStrip(in:)` exists at all: the tiles are
    /// `accessibilityHidden`, so the heading is the only part of the strip a
    /// test can see — and here it says how many arrived, which is the number
    /// that goes onto the listing.
    @MainActor
    private func reviewPhotoHeading(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Photos"))
            .firstMatch
    }

    /// Opens a queued submission and waits for its preview to have loaded,
    /// mirroring `openCommunityHike(titled:in:)` — including the re-offered
    /// *Search this area* pill, since the map can settle twice. Both reach for
    /// that through `awaitCommunityAnswer(_:in:)`, which is where the argument
    /// for it lives.
    @MainActor
    private func openQueuedSubmission(titled title: String, in app: XCUIApplication) {
        let row = communityRow(titled: title, in: app)
        XCTAssertTrue(
            awaitCommunityAnswer(row, in: app),
            "\"\(title)\" should be waiting before it can be opened"
        )
        row.tap()
        // The *Submission* header rather than the decision below it. The sheet
        // opens at its middle detent and a `Form` builds its rows lazily, so
        // the buttons at the foot of this screen are not in the element tree
        // until something scrolls to them — which is a thing each test does
        // for itself, not a thing "the screen opened" should mean.
        XCTAssertTrue(
            app.staticTexts["Submission"].waitForExistence(timeout: UITestTimeout.trace),
            "the review screen should have drawn what is being decided"
        )
    }
}
