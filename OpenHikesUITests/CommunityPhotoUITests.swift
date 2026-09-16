//
//  CommunityPhotoUITests.swift
//  OpenHikesUITests
//
//  Photographs somebody added to a trail they did not publish.
//
//  ``SeededCommunityTransport`` hangs one contributed set on a published hike
//  whose own author published no photographs, and one on an OpenStreetMap
//  route — which carries none because nothing curated ever does. That pairing
//  is what this class is for: the two targets go through
//  ``CommunityIdentity`` into one code path, and the curated half is the one
//  with no record anywhere in the database for a contribution to point at.
//
//  What is faked is only the transport. These pictures are real JPEGs written
//  to disk, read back through the real decode, merged by the real
//  ``CommunityHikeDetail/galleryPhotos``, and drawn by the real strip and the
//  real viewer — so a case that opens one is testing the app.
//
//  Three things are asserted, and each is something nothing else can reach:
//
//  - **A trail with no photographs of its own gets some.** That is the whole
//    feature, and before it a curated route's screen had no strip at all.
//  - **The credit is on the photograph.** These sit on a screen headed with
//    somebody else's name, so the credit is the only thing saying whose they
//    are — and it is drawn in the navigation title, because the page is a
//    picture edge to edge and a caption would sit on top of it.
//  - **Report and Block are about the contributor.** Guideline 1.2's two
//    halves follow the content rather than the hike: blocking whoever
//    published the trail would hide nothing about a photograph somebody else
//    put on it.
//
//  What is deliberately *not* here is the merged numbering, where an
//  author's pictures come first and a contributed set follows.
//  ``CommunityContributedGalleryTests`` asks about that directly and can, and
//  reaching it from a launch would mean hanging a set on the one seeded hike
//  whose gallery size `CommunityUITests` already pins.
//

import XCTest

nonisolated final class CommunityPhotoUITests: XCTestCase {
    // MARK: - A trail that had none

    /// The published half: a hike whose author shared no photographs, opened
    /// after somebody else added three.
    @MainActor
    func testAPublishedHikeShowsPhotographsSomebodyElseAdded() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.lakeTitle, in: app)

        XCTAssertTrue(
            communityPhotoStrip(in: app).waitForExistence(timeout: UITestTimeout.trace),
            "a hike with contributed photographs should draw a strip for them"
        )
        for index in 0..<SeededContribution.photoCount {
            XCTAssertTrue(
                communityPhotoTile(at: index, in: app)
                    .waitForExistence(timeout: UITestTimeout.existence),
                "contributed photograph \(index + 1) should be in the strip"
            )
        }
    }

    /// The curated half, and the one that could not work by accident: an
    /// OpenStreetMap route has no record in the public database, so a
    /// contribution reaching it proves the target is an identity rather than a
    /// reference.
    @MainActor
    func testAnOpenStreetMapRouteShowsPhotographsSomebodyAdded() {
        let app = launchCommunity(scenario: .curated)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededCuratedTrail.loopTitle, in: app)

        XCTAssertTrue(
            communityPhotoStrip(in: app).waitForExistence(timeout: UITestTimeout.trace),
            "an OpenStreetMap route with contributed photographs should draw a strip"
        )
        XCTAssertTrue(
            communityPhotoTile(at: 0, in: app).waitForExistence(timeout: UITestTimeout.existence),
            "the first contributed photograph should be in the strip"
        )
    }

    // MARK: - Whose photograph it is

    /// The credit, which is the only thing on this screen saying that these
    /// pictures are not the hike author's.
    @MainActor
    func testAContributedPhotographIsCreditedToWhoeverAddedIt() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.lakeTitle, in: app)

        tapWhenReady(communityPhotoTile(at: 0, in: app))

        XCTAssertTrue(
            element("community-photo-viewer", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "tapping a contributed photograph should open it large"
        )
        XCTAssertTrue(
            app.navigationBars["1 of \(SeededContribution.photoCount) · by \(SeededContribution.author)"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "the gallery should say who added the photograph it is showing"
        )
    }

    // MARK: - Guideline 1.2, on the photograph

    /// Both halves, on the picture rather than on the hike. The menu names the
    /// contributor — not whoever published the trail — which is the whole
    /// reason it exists: blocking the trail's author would hide nothing about
    /// somebody else's photograph on it.
    @MainActor
    func testAContributedPhotographCanBeReportedAndItsAuthorBlocked() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.lakeTitle, in: app)

        tapWhenReady(communityPhotoTile(at: 0, in: app))
        tapWhenReady(element("community-photo-actions", in: app))

        XCTAssertTrue(
            element("community-photo-report", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a contributed photograph should be reportable"
        )
        let block = element("community-photo-block", in: app)
        XCTAssertTrue(
            block.waitForExistence(timeout: UITestTimeout.existence),
            "a contributed photograph's author should be blockable"
        )
        XCTAssertTrue(
            block.label.contains(SeededContribution.author),
            """
            the block item should name whoever added the photograph, not \
            whoever published the hike — it read "\(block.label)"
            """
        )
    }

    /// The hike author's own photographs get no such menu, and that absence is
    /// the statement: reporting or blocking over one of those is about the
    /// hike, and the hike's own screen one push back already offers both. Two
    /// doors to the same two actions naming different records is the bug this
    /// menu exists to prevent.
    @MainActor
    func testTheHikeAuthorsOwnPhotographHasNoPerPhotoMenu() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        // The ridge's two are its author's own, and it has no contributions.
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        tapWhenReady(communityPhotoTile(at: 0, in: app))

        XCTAssertTrue(
            element("community-photo-viewer", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the gallery should open"
        )
        XCTAssertFalse(
            element("community-photo-actions", in: app)
                .waitForExistence(timeout: UITestTimeout.brief),
            "the hike author's own photograph should carry no per-photo menu"
        )
    }
}
