//
//  CommunityPublishedPhotosUITests.swift
//  OpenHikesUITests
//
//  What a hike that is already live offers when its author comes back to it.
//
//  This is the one state in the app that could publish a duplicate, and it
//  could do it in a single tap. A published hike's menu led with *Share
//  Again*; a submission cannot be amended, so that made a second listing of
//  the same walk and pointed this device at it, leaving the first live,
//  findable and invisible to the person who made it. The hiker's actual errand
//  — the photographs they got off the camera after the walk went up — had
//  nowhere to go at all.
//
//  So the assertion is in two halves, and the negative one is the point:
//  *Add Photos to This Trail* is there, and *Share Again* is gone. A unit test
//  can pin where a contribution is aimed, and does — see
//  ``CommunityOwnListingPhotosTests``. Only a launch can say what the menu on
//  a live hike puts under the hiker's thumb.
//
//  The scenario is ``SeededCommunityScenario/published``, which is the only
//  way automation reaches that state: ``CommunityPublicationCheck`` writes
//  ``Hike/communityListingID`` from `publication(of:)`'s answer, and nothing
//  else does.
//

import XCTest

nonisolated final class CommunityPublishedPhotosUITests: XCTestCase {
    /// The menu on a live hike, and the form behind its first item.
    @MainActor
    func testAPublishedHikeOffersPhotographsRatherThanASecondCopy() {
        let app = shareTheImportedHike()

        // Back out and in again, which is what asks the publication check a
        // second time: it runs from a `.task(id: hike.id)` on the share
        // button, and the id does not change when a submission is written, so
        // its first run was against a hike that had none. Re-entering is also
        // what a hiker does.
        popScreen(in: app)
        openHikeDetail(in: app)

        tapWhenReady(element("community-share-button", in: app))
        let addPhotos = element("community-add-photos-button", in: app)
        XCTAssertTrue(
            addPhotos.waitForExistence(timeout: UITestTimeout.existence),
            "a published hike should offer to add photographs to the trail it already is"
        )
        XCTAssertFalse(
            app.buttons["Share Again"].exists,
            "and must not offer a second copy of a walk that is already in the list"
        )
        XCTAssertTrue(
            element("community-liveness-button", in: app).exists,
            """
            and must offer the one item that is about the listing itself — without \
            it a hike taken down has no way back to being shareable
            """
        )

        tapWhenReady(addPhotos)
        XCTAssertTrue(
            element("community-photos-target", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the form should name the trail the photographs are going on"
        )
        XCTAssertTrue(
            element("community-photos-reason", in: app).exists,
            """
            and say why the walk itself is staying put — a published hike has no \
            refusal behind it, so this is the one target whose footer comes from \
            somewhere else
            """
        )
    }

    /// Imports the bundled GPX, shares it, and leaves the hike's own screen on
    /// top with a submission against it.
    ///
    /// The same four taps of setup ``AccessibilityUITests`` makes for the
    /// withdrawal form, and made again here rather than shared: that copy is
    /// private to an audit class whose launches carry different arguments, and
    /// a helper reached across two classes to save four lines is how one
    /// class's scenario quietly becomes another's.
    @MainActor
    private func shareTheImportedHike(
        scenario: SeededCommunityScenario = .published
    ) -> XCUIApplication {
        let app = launchCommunity(
            scenario: scenario,
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
            "the menu this class is about needs a submission to be about"
        )
        app.buttons["Done"].firstMatch.tap()
        return app
    }

    /// The other half of dropping *Share Again*: a takedown has to be
    /// survivable.
    ///
    /// Nothing tells this device when a reviewer removes a listing, so a
    /// published hike goes on reading published — and since it is published it
    /// offers no share form, aims its photographs at a listing that is gone,
    /// and is refused as a retread if the walk is recorded again. Every way
    /// out is shut. This walks the way back in: ask, be told, reset, share.
    ///
    /// ``SeededCommunityScenario/takenDown`` is what makes it reachable — one
    /// yes from `publication(of:)` so the device believes it is live, and
    /// `nil` afterwards. Believing it first is the point; a scenario that
    /// always said `nil` would never reach the published menu at all.
    @MainActor
    func testAHikeWhoseListingIsGoneCanBeSharedAgain() {
        let app = shareTheImportedHike(scenario: .takenDown)
        popScreen(in: app)
        openHikeDetail(in: app)

        tapWhenReady(element("community-share-button", in: app))
        let check = element("community-liveness-button", in: app)
        XCTAssertTrue(
            check.waitForExistence(timeout: UITestTimeout.existence),
            "a live hike should offer to check whether it is still live"
        )
        tapWhenReady(check)

        let reset = element("community-liveness-reset-button", in: app)
        XCTAssertTrue(
            reset.waitForExistence(timeout: UITestTimeout.existence),
            "a hike whose listing has gone should say so and offer the way back"
        )
        tapWhenReady(reset)

        // The assertion that matters is not the alert but what the hike can do
        // afterwards: the share form is the thing a published hike does not
        // have, so reaching it is proof the reset undid the publication rather
        // than only the badge.
        tapWhenReady(element("community-share-button", in: app))
        XCTAssertTrue(
            element("community-author-field", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "a forgotten hike should be shareable again, which is the whole point of forgetting it"
        )
    }
}
