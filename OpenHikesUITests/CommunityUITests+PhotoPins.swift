//
//  CommunityUITests+PhotoPins.swift
//  OpenHikesUITests
//
//  The loop between a stranger's gallery and the map under it.
//
//  Two things used to be missing from it, and they are the two halves of one
//  complaint: *Show on map* moved the camera to a photograph's coordinate and
//  left the reviewer looking at a closed marker among markers, and the picture
//  inside a photo pin's callout opened nothing at all — the strip on the sheet
//  was the only way into ``CommunityPhotoViewer``.
//
//  Both are asserted here in one pass, because they are one journey: out of the
//  gallery onto the map, and back into the gallery from it. Driven through the
//  real seeded transport, the real pins and MapKit's own callout, so what is
//  being watched is the app rather than a stand-in for it.
//

import XCTest

nonisolated final class CommunityPhotoPinUITests: XCTestCase {
    /// Out of the gallery and back in again.
    ///
    /// The middle assertion is the one that had no way of failing before: the
    /// preview inside the callout only exists while the callout is open, so
    /// finding it is finding a pin that opened itself.
    @MainActor
    func testShowOnMapOpensThePinAndItsPictureReopensTheGallery() {
        let app = launchCommunity(scenario: .seeded)
        selectCommunityTab(in: app)
        openCommunityHike(titled: SeededHike.ridgeTitle, in: app)

        tapWhenReady(communityPhotoTile(at: 0, in: app))
        let viewer = element("community-photo-viewer", in: app)
        XCTAssertTrue(
            viewer.waitForExistence(timeout: UITestTimeout.existence),
            "tapping a photograph should open the gallery"
        )

        let showOnMap = element("community-photo-show-on-map-button", in: app)
        XCTAssertTrue(
            showOnMap.waitForExistence(timeout: UITestTimeout.existence),
            "an anchored photograph should offer to show where it was taken"
        )
        showOnMap.tap()

        // The callout, not the marker. A closed pin has no preview in it, so
        // this existing at all is the map having opened the one it was sent to.
        //
        // Waited for together with its position rather than in two steps: the
        // sheet is still settling to its middle detent while the camera moves,
        // so a frame read the moment the preview appears is a frame read
        // mid-animation. Above the sheet is also what makes the tap below a
        // test of the callout rather than of whatever the sheet is showing —
        // the same framing ``PhotoUITests`` asserts for the hiker's own pins.
        let sheet = element("map-sheet", in: app)
        let preview = element("community-photo-pin-preview", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                preview.exists && sheet.exists && preview.frame.maxY < sheet.frame.minY
            },
            "showing a photograph on the map should open that pin's callout, clear of the sheet"
        )

        preview.tap()
        XCTAssertTrue(
            viewer.waitForExistence(timeout: UITestTimeout.navigation),
            "tapping a pin's picture should open the gallery at that photograph"
        )
        XCTAssertTrue(
            app.navigationBars["1 of \(SeededHike.ridgePhotoCount)"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "the gallery should reopen on the photograph whose pin was tapped"
        )
    }
}
