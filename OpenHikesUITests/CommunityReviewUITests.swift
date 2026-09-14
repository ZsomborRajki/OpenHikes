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
        XCTAssertTrue(
            communityRow(titled: SeededHike.ridgeTitle, in: app).exists,
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
        // Enabled only once the submission has loaded, which is not a detail of
        // the test: the photo count that goes onto the listing arrives with the
        // photographs, and a reviewer publishing before them would be approving
        // a title. See `CommunityReviewView.hasLoaded`.
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
        element("community-moderation-menu", in: reviewing).tap()
        XCTAssertTrue(
            element("community-take-down-button", in: reviewing)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a reviewer should be able to unlist a published hike"
        )
        reviewing.terminate()

        let browsing = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: browsing)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: browsing)
        element("community-moderation-menu", in: browsing).tap()
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
    /// *Search this area* pill, since the map can settle twice.
    @MainActor
    private func openQueuedSubmission(titled title: String, in app: XCUIApplication) {
        let row = communityRow(titled: title, in: app)
        let pill = element("community-search-this-area", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.trace) {
                if row.exists { return true }
                if pill.exists { pill.tap() }
                return false
            },
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
