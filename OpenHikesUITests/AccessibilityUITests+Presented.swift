//
//  AccessibilityUITests+Presented.swift
//  OpenHikesUITests
//
//  The two presented screens the sweep never saw.
//
//  `AccessibilityUITests` audits the screens the app *navigates* to, and both
//  of these are reached by presenting something over one of them — which is
//  how they were missed. The map's audit covers "the map, the weather badge
//  and the sheet's search", and the badge is the *button*; the sheet it opens
//  is a separate presentation. The paywall is behind a row in Settings, and
//  the Settings audit ends at the screen the row is on.
//
//  Not a second test class — SwiftLint's `single_test_class` forbids one, and
//  a new class would also have to be added to the list of functional classes
//  `Scripts/run-ui-tests.sh` names. An extension keeps both facts unchanged,
//  exactly as `AccessibilityUITests+Community.swift` does: these are
//  `AccessibilityUITests` methods, they run in the `accessibility-ui-tests`
//  job with the rest, and `--suite AccessibilityUITests` still selects them.
//
//  A separate file from that one because the class itself has no room: it
//  measures 420 lines against `type_body_length`'s error at 450, and these two
//  do not belong under a header about Community forms.
//

import XCTest

extension AccessibilityUITests {
    /// The paywall, which is the one screen where a failure costs a purchase.
    ///
    /// It is also the densest layout the app has outside hike detail — a
    /// feature list built by `featureRow`, the `SubscriptionStoreView` adopted
    /// in #420 and therefore drawing controls this app did not lay out, a
    /// restore button, and the subscription disclosure — and the screen most
    /// likely to be read by App Review.
    ///
    /// Reached through *OpenHikes Pro* in the About section rather than
    /// through a locked row in Map Tiles, for the reason
    /// `SettingsUITests.testProIsReachableWithoutTheMapTilesSection` exists:
    /// that is the entry point which reads no entitlement, no product and no
    /// key, so it is the one that works in a build without `Secrets.plist` and
    /// the one an audit can rely on.
    ///
    /// **Only the unentitled state, and that is not an omission being made
    /// quietly.** The issue this closes asks for both, and the other one is
    /// not a screen: the row is absent for a subscriber — they have *Manage
    /// Subscription* in Map Tiles — and `MapPaywallView` dismisses itself the
    /// moment the store answers, which is what
    /// `SettingsUITests.testProRowIsAbsentForASubscriber` and the comment on
    /// `testPrivacyPolicyIsReachableWithoutThePaywall` already pin. There is
    /// nothing on screen for an audit to walk. The *disabled-row* state that
    /// issue also names is a build without API keys, which this one is not —
    /// `testProIsReachableWithoutTheMapTilesSection` says the same thing in
    /// the same words.
    @MainActor
    func testPaywallPassesAccessibilityAudit() throws {
        let app = launchApp()

        element("settings-button", in: app).tap()
        XCTAssertTrue(
            element("settings-screen", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        let pro = element("about-pro-link", in: app)
        XCTAssertTrue(
            scrollIntoView(pro, in: app),
            "Settings should offer OpenHikes Pro outside the Map Tiles section"
        )
        pro.tap()

        XCTAssertTrue(
            element("map-paywall", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "the audit is worth nothing against a paywall that has not drawn yet"
        )
        // The restore button rather than the paywall's own identifier. The
        // sheet exists before `SubscriptionStoreView` has laid its controls
        // out, and the controls are most of what there is here to audit — so
        // waiting on the container would sweep a screen that is still mostly
        // empty and report that it passed.
        XCTAssertTrue(
            element("paywall-restore-button", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "Restore Purchases is drawn once the store screen has settled"
        )

        try audit(app)
    }

    /// The weather sheet, which the map's audit has only ever seen as a badge.
    ///
    /// Seven identified regions — the conditions grid, the hourly strip, wind,
    /// the reading's age, the unavailability row, the Apple Weather credit and
    /// the legal link — none of which the map's sweep reaches, because the
    /// badge is a button and the sheet is a presentation over it.
    ///
    /// #425 is why this is worth a case rather than an assumption: the wind
    /// row was missing from that sheet and the functional suite had been red
    /// on it, which is the shape of thing that goes unnoticed on a screen
    /// nothing sweeps.
    ///
    /// `--ui-test-weather` is what makes it reachable at all — the real
    /// WeatherKit reading is a network answer no suite may wait on — and the
    /// gesture is the one `OpenHikesUITests.testTheWeatherBadgeOpensTheWhole`
    /// `Reading` already makes.
    @MainActor
    func testWeatherDetailSheetPassesAccessibilityAudit() throws {
        let app = launchApp(arguments: ["--ui-test-weather"])

        tapWhenReady(element("weather-badge", in: app))
        XCTAssertTrue(
            element("weather-detail-conditions", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the audit is worth nothing against a sheet that has not drawn yet"
        )
        // The wind row is the last of the seven to arrive and the one #425 was
        // about, so it is what says the sheet is whole rather than opening.
        XCTAssertTrue(
            element("weather-detail-wind", in: app)
                .waitForExistence(timeout: UITestTimeout.existence),
            "the rest of the reading should be on screen before it is swept"
        )

        try audit(app)
    }
}
