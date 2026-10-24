//
//  FirstRunTipsUITests.swift
//  OpenHikesUITests
//
//  The first-run tips, in the order a first launch meets them: the two
//  buttons on the map, the *Community* tab and its pill, then the recording
//  screen's two places buttons — and the owner's rule for an existing hiker,
//  who is never told how to make a hike.
//
//  `--ui-test-tips` is what turns them on. Every other launch under automation
//  has no tips at all — see `TipLaunch` — so this is the one class that ever
//  sees one, and each of its launches starts from an empty tip store.
//
//  The tips about the map's own buttons are cards on the map, read the way
//  VoiceOver reads them: one element, labelled with the tip's title — see
//  `MapTipCardView`, and the measurement there of why a bare TipKit card on
//  the map was nowhere in the tree. The others are TipKit's own views, found
//  by their titles.
//

import XCTest

nonisolated final class FirstRunTipsUITests: XCTestCase {
    /// Where TipKit draws a card's ✕, from the card's top trailing corner.
    private static let closeButtonInset: CGFloat = 27

    /// One at a time, each waiting for the one before it: the two about the
    /// map's buttons over the pill, the *Community* tab's under the picker,
    /// and its pill's once the tab has answered.
    @MainActor
    func testTheMainScreenTipsComeOneAtATime() {
        let app = launchCommunity(scenario: .curated, extraArguments: ["--ui-test-tips"])

        let record = mapTip("Record a Hike", in: app)
        awaitTip(record, in: app, "a first launch explains the record button", timeout: UITestTimeout.trace)
        XCTAssertFalse(mapTip("Make a Trail", in: app).exists, "one tip at a time")
        closeMapTip(record)

        let makeTrail = mapTip("Make a Trail", in: app)
        awaitTip(makeTrail, in: app, "the maker's button is next")
        XCTAssertTrue(record.waitForNonExistence(timeout: UITestTimeout.existence), "a closed tip goes")
        closeMapTip(makeTrail)

        let findTrails = app.staticTexts["Find Trails"]
        awaitTip(findTrails, in: app, "then the Community tab, under its picker")

        let community = app.buttons["Community"]
        XCTAssertTrue(tapUntilSelected(community), "tapping Community should select it")
        XCTAssertTrue(
            findTrails.waitForNonExistence(timeout: UITestTimeout.existence),
            "choosing the tab is what its tip was asking for"
        )

        let searchElsewhere = mapTip("Search Somewhere Else", in: app)
        awaitTip(
            searchElsewhere,
            in: app,
            "the pill's tip arrives once the tab has answered",
            timeout: UITestTimeout.trace
        )
        tapWhenReady(element("community-search-this-area", in: app))
        XCTAssertTrue(
            searchElsewhere.waitForNonExistence(timeout: UITestTimeout.existence),
            "and goes once the pill has been used"
        )
    }

    /// The owner's rule: the two tips about making a hike are for a library
    /// with nothing in it. The *Community* tab's is for anybody who has not
    /// used the tab yet, existing hikers included.
    @MainActor
    func testAHikerWithHikesIsNotToldHowToMakeOne() {
        let app = launchCommunity(
            scenario: .curated,
            extraArguments: ["--ui-test-tips", "--ui-test-seed-hikes=1"]
        )

        awaitTip(
            app.staticTexts["Find Trails"],
            in: app,
            "the Community tab's tip still shows",
            timeout: UITestTimeout.trace
        )
        XCTAssertFalse(mapTip("Record a Hike", in: app).exists, "the record button needs no introduction")
        XCTAssertFalse(mapTip("Make a Trail", in: app).exists, "nor the maker's")
    }

    /// *Add Place* first, once the walk has a fix to put a place at, then
    /// *Places Nearby* beside it — and a closed tip stays closed when the
    /// screen comes back.
    @MainActor
    func testTheRecordingTipsComeOneAtATime() {
        let app = makeApp(
            arguments: [
                "--ui-test-tips",
                "--ui-test-enable-location",
                "--ui-test-trail-points=seeded",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence),
            "the walk needs a fix before a place can be marked"
        )
        walkRecordedTrace([UITestFixture.trailheadCoordinate], countedBy: points)

        let markAPlace = app.staticTexts["Mark a Place"]
        awaitTip(markAPlace, in: app, "a walk with a fix explains Add Place")
        closeTip(in: app)

        let around = app.staticTexts["What’s Around You"]
        awaitTip(around, in: app, "then Places Nearby, beside it")
        closeTip(in: app)
        XCTAssertTrue(around.waitForNonExistence(timeout: UITestTimeout.existence), "a closed tip goes")

        tapWhenReady(element("recording-places-nearby", in: app))
        XCTAssertTrue(
            element("places-nearby-list", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "Places Nearby still opens"
        )
        popScreen(in: app)
        XCTAssertTrue(app.navigationBars["Record Hike"].waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertFalse(
            around.waitForExistence(timeout: UITestTimeout.brief) || markAPlace.exists,
            "and neither comes back"
        )
    }
}

private extension FirstRunTipsUITests {
    /// The card of a tip about one of the map's buttons, by its title.
    @MainActor
    func mapTip(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.otherElements
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "map-tip", title))
            .firstMatch
    }

    /// Waits for a tip, and leaves a picture behind if it never comes: a tip
    /// drawn but missing from the accessibility tree fails exactly like one
    /// that was never drawn, and only the picture tells them apart.
    @MainActor
    func awaitTip(
        _ tip: XCUIElement,
        in app: XCUIApplication,
        _ message: String,
        timeout: TimeInterval = UITestTimeout.existence,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !tip.waitForExistence(timeout: timeout) else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail(message, file: file, line: line)
    }

    /// Closes a card on the map with TipKit's ✕, by where it is drawn.
    ///
    /// By position because the ✕ is inside the view MapKit leaves out of the
    /// tree, and the card's own *Close* is an accessibility action, which
    /// VoiceOver performs and automation cannot.
    @MainActor
    func closeMapTip(_ card: XCUIElement) {
        card.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: -Self.closeButtonInset, dy: Self.closeButtonInset))
            .tap()
    }

    /// Closes one of TipKit's own views with its ✕, which TipKit puts in the
    /// tree wherever MapKit is not in the way.
    @MainActor
    func closeTip(in app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(
            close.waitForExistence(timeout: UITestTimeout.existence),
            "a tip carries its own close button\n\(app.debugDescription)"
        )
        close.tap()
    }
}
