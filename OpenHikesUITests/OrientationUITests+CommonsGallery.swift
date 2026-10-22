//
//  OrientationUITests+CommonsGallery.swift
//  OpenHikesUITests
//
//  The gallery a Wikimedia Commons photograph's screen opens, turned over
//  while it is up, and where its credit stands once it has been.
//
//  It was a cover presented from inside the sheet, and a rotation moves the
//  sheet's screens to the side panel — a different host — which took the
//  cover down with the old one: the hiker turned the phone to see a picture
//  bigger and was dropped back on the screen they had opened it from. Pushed
//  onto the sheet's stack now, as the other two galleries are, so a rotation
//  moves it rather than closing it.
//
//  And turned on its side, the credit across the bottom sat on the picture
//  the hiker had turned the phone to see. It stands at the leading edge
//  there, in the black a photograph leaves either side of itself — see
//  `PhotoGalleryControls.swift`.
//
//  Split out of `OrientationUITests` for the reason `+Gallery` is.
//

import XCTest

extension OrientationUITests {
    /// Opened in portrait, paged once, turned both ways: still up, still on
    /// the page it was left at, and still answering its buttons.
    @MainActor
    func testACommonsGalleryStaysOpenThroughARotation() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        XCUIDevice.shared.orientation = .portrait
        let app = launchCommunity(scenario: .commons)
        XCTAssertTrue(waitForPortrait(app), "the app should have started upright")
        selectCommunityTab(in: app)
        let pin = communityCommonsPhotoPin(in: app)
        XCTAssertTrue(
            pin.waitForExistence(timeout: UITestTimeout.trace),
            "precondition: the tab's search should put the area's photographs on the map"
        )
        pin.tap()
        tapWhenReady(element("commons-photo-header", in: app))
        let gallery = element("community-photo-viewer", in: app)
        XCTAssertTrue(
            gallery.waitForExistence(timeout: UITestTimeout.navigation),
            "precondition: the photograph should open its gallery"
        )
        tapWhenReady(app.buttons["Next photo"])
        let secondPage = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "2 of "))
            .firstMatch
        XCTAssertTrue(secondPage.waitForExistence(timeout: UITestTimeout.navigation))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                gallery.exists && gallery.frame.width > app.frame.width * Self.minimumFilledWindowShare
            },
            "turned to landscape, the gallery should stay up and take the window"
        )
        XCTAssertTrue(secondPage.exists, "on the page it was left at")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        XCTAssertTrue(
            secondPage.waitForExistence(timeout: UITestTimeout.navigation),
            "turned back upright, the gallery should still be on that page"
        )
        // A tap that lands only on a gallery that is still there — a closing
        // one is gone by the time it would answer.
        tapWhenReady(app.buttons["Next photo"])
        XCTAssertTrue(
            app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "3 of ")).firstMatch
                .waitForExistence(timeout: UITestTimeout.navigation),
            "and go on paging"
        )
    }

    /// Opened in landscape, the credit stands at the leading edge, clear of
    /// the photograph — measured against where the picture is drawn, which is
    /// its page with the seeded 4:3 frame fitted into it and centred.
    @MainActor
    func testALandscapeGalleryCreditsBesideThePhotograph() {
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
        XCUIDevice.shared.orientation = .portrait
        let app = launchCommunity(scenario: .commons)
        XCTAssertTrue(waitForPortrait(app), "the app should have started upright")
        selectCommunityTab(in: app)
        // Tapped upright: the pins stand across the middle of the map above
        // the sheet, and in landscape the panel is over the leading third of it.
        let pin = communityCommonsPhotoPin(in: app)
        XCTAssertTrue(pin.waitForExistence(timeout: UITestTimeout.trace))
        pin.tap()
        let header = element("commons-photo-header", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: UITestTimeout.navigation))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        tapWhenReady(header)
        let gallery = element("community-photo-viewer", in: app)
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.navigation) {
                gallery.exists && gallery.frame.width > app.frame.width * Self.minimumFilledWindowShare
            },
            "precondition: the gallery should take the window"
        )

        // The credit, and not the map's pin under the gallery, which is
        // called the same thing.
        let credit = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "Photo by \(SeededCommons.firstAuthor) · \(SeededCommons.license)",
                "community-commons-photo-pin"
            )
        ).firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: UITestTimeout.existence))
        // The page the gallery opened at, which its label names.
        let page = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", ", by \(SeededCommons.firstAuthor),"))
            .firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: UITestTimeout.existence))
        let pictureWidth = min(page.frame.width, page.frame.height * SeededCommons.aspectRatio)
        let pictureMinX = page.frame.midX - pictureWidth / 2
        XCTAssertLessThan(
            credit.frame.midX,
            app.frame.midX,
            "the credit should stand at the leading edge"
        )
        XCTAssertLessThanOrEqual(
            credit.frame.maxX,
            pictureMinX,
            "in the black beside the photograph rather than on it"
        )
    }
}
