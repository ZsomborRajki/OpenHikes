//
//  CommunityUITests+SwitchingPreviews.swift
//  OpenHikesUITests
//
//  One stranger's preview replaced by another's, from the map behind it.
//
//  A pin tapped over an open preview replaces it rather than stacking on it —
//  see ``SheetPresentation/showCommunityHike(_:)``. The path went from `[A]` to
//  `[B]`, and the screen took the new title and kept everything else: the
//  route, the photographs and the Add button were still A's until the hiker
//  backed out and opened B again.
//

import XCTest

extension CommunityUITests {
    /// The ridge from its row, then the lake from its pin: the page is the
    /// lake's.
    ///
    /// The strip is the tell, counted rather than looked for, because both
    /// hikes have one: the ridge's own two photographs, and the three Cass
    /// contributed to the lake. A third tile is the lake's page; a page that
    /// kept the ridge's answer never draws one.
    ///
    /// That way round because it is the one the map allows: the ridge's
    /// framing leaves the lake's pin above the sheet, and the scramble's —
    /// the hike with no photographs at all — leaves it under it.
    @MainActor
    func testOpeningAnotherHikesPinOverAPreviewShowsThatHike() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)
        let lastLakePhoto = communityPhotoTile(at: SeededContribution.photoCount - 1, in: app)
        XCTAssertTrue(
            communityPhotoTile(at: SeededHike.ridgePhotoCount - 1, in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "precondition: the ridge's preview shows its photographs"
        )
        XCTAssertFalse(lastLakePhoto.exists, "precondition: and only its own two")

        let lakePin = app.descendants(matching: .any)
            .matching(identifier: "community-hike-pin")
            .matching(NSPredicate(format: "label CONTAINS %@", SeededHike.lakeTitle))
            .firstMatch
        tapWhenReady(lakePin)
        tapWhenReady(element("community-pin-open", in: app))

        XCTAssertTrue(
            app.navigationBars[SeededHike.lakeTitle].waitForExistence(timeout: UITestTimeout.navigation),
            "the lake's pin should open the lake's preview"
        )
        XCTAssertTrue(
            lastLakePhoto.waitForExistence(timeout: UITestTimeout.trace),
            "the lake's page shows Cass's three photographs; two is the ridge's page under the lake's title"
        )
    }
}
