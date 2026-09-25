//
//  SettingsUITests.swift
//  OpenHikesUITests
//
//  The settings screen and what it governs: which tile provider is in use and
//  what that provider is allowed to do, and the two toggles that outlive the
//  screen they are set on.
//

import XCTest

nonisolated final class SettingsUITests: XCTestCase {
    /// OpenStreetMap is passive auto-save only, and the detail screen is where
    /// that policy is either honoured or quietly broken.
    ///
    /// The button is absent rather than disabled, which is the stronger
    /// statement: there is nothing to press. Asserting it here means the
    /// policy is checked against the screen a user would use to violate it,
    /// not only against the flag it is read from.
    @MainActor
    func testOffersNoBulkDownloadOnOpenStreetMap() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        element("settings-button", in: app).tap()
        let osm = element("provider-row-osm", in: app)
        XCTAssertTrue(
            osm.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(
            osm.isSelected,
            "OpenStreetMap is the keyless default this app ships on"
        )
        app.buttons["Done"].tap()

        openHikeDetail(in: app)
        scrollIntoView(element("route-style-row", in: app), in: app)
        XCTAssertFalse(
            element("offline-download-button", in: app).exists,
            "a provider that forbids bulk download must not offer the button"
        )
    }

    /// The Apple Maps option's whole promise is negative: with it selected
    /// there is no bulk download to press and no auto-save to switch on,
    /// because nothing draws a tile that either could act on. Asserted on the
    /// screen a user would reach for them, for the same reason the OSM policy
    /// above is — the flags behind both are pinned in `TileProviderTests`, but
    /// a control left on screen is what a user would actually experience.
    @MainActor
    func testSystemBaseMapOffersNoTileControls() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        element("settings-button", in: app).tap()
        let appleMaps = element("provider-row-apple_maps", in: app)
        XCTAssertTrue(
            appleMaps.waitForExistence(timeout: UITestTimeout.navigation)
        )
        appleMaps.tap()
        XCTAssertTrue(appleMaps.isSelected, "the tapped source should become the selected one")
        app.buttons["Done"].tap()

        openHikeDetail(in: app)
        scrollIntoView(element("route-style-row", in: app), in: app)
        XCTAssertFalse(
            element("offline-download-button", in: app).exists,
            "a map that fetches no tiles has nothing to download"
        )
        XCTAssertFalse(
            app.switches["Auto-Save Tiles"].exists,
            "a map that fetches no tiles has nothing to auto-save"
        )
    }

    /// The settings toggle, flipped and then found still flipped after the
    /// screen has been left and re-entered.
    ///
    /// One toggle rather than two since the cellular switch was removed —
    /// what the app puts on the radio is decided from live conditions now, not
    /// from a stored preference. Background Trail Tracking is not a substitute
    /// here: flipping it asks for location authorization.
    ///
    /// Within one launch, deliberately: UI-testing defaults are wiped at
    /// startup, so a relaunch could never show anything but the default and an
    /// assertion across one would be testing the harness. Push and pop is the
    /// part that is the app's — `@AppStorage` writing through on a screen that
    /// has been torn down and rebuilt.
    @MainActor
    func testSettingsTogglesHoldTheirValue() {
        let app = launchApp()

        element("settings-button", in: app).tap()
        XCTAssertTrue(
            element("settings-screen", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )

        let photos = toggle("save-photos-to-library-toggle", in: app)
        XCTAssertTrue(
            scrollIntoView(photos, in: app),
            "the toggle has to be fully on screen before it can be aimed at"
        )
        let photosBefore = toggleIsOn(photos)
        flip(photos)
        XCTAssertTrue(
            waitUntilToggle(photos, is: !photosBefore),
            "tapping a toggle should flip it"
        )

        app.buttons["Done"].tap()
        element("settings-button", in: app).tap()
        XCTAssertTrue(
            element("settings-screen", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )

        XCTAssertTrue(scrollIntoView(photos, in: app))
        XCTAssertEqual(
            toggleIsOn(photos),
            !photosBefore,
            "a toggle's value should survive its screen being rebuilt"
        )
    }

    /// The privacy policy, reached from Settings alone.
    ///
    /// App Review 5.1.1(i) fails a binary whose policy is not linked inside the
    /// app, and the link used to live only in the paywall's purchase
    /// disclosure. Asserted from both ends that could not reach it: a free
    /// launch, where the paid rows that open the paywall are disabled in a
    /// build without their API keys, and an entitled one, where the paywall
    /// dismisses itself the moment the store answers. Neither may need it.
    ///
    /// Neither link is tapped. A `Link` hands the URL to Safari, which takes
    /// the test out of the app for an assertion about a web page. The rows
    /// spend the same `MapPurchaseLinks` constants the paywall and the share
    /// forms do; no suite pins the URLs themselves any more, since the one
    /// that did went with the paywall's hand-built disclosure.
    @MainActor
    func testPrivacyPolicyIsReachableWithoutThePaywall() {
        for arguments in [[], ["--ui-test-entitled"]] {
            let app = launchApp(arguments: arguments)

            element("settings-button", in: app).tap()
            XCTAssertTrue(
                element("settings-screen", in: app)
                    .waitForExistence(timeout: UITestTimeout.navigation)
            )

            XCTAssertTrue(
                scrollIntoView(element("privacy-policy-link", in: app), in: app),
                "Settings should link the privacy policy on a \(arguments) launch"
            )
            // The terms belong here for a sharper version of the same reason.
            // They are what a hiker agrees to by publishing a hike, publishing
            // is free, and the paywall is the one screen that need never be
            // opened — so a hiker can be bound by them having passed nothing
            // that links them.
            XCTAssertTrue(
                scrollIntoView(element("terms-link", in: app), in: app),
                "Settings should link the terms on a \(arguments) launch"
            )
            XCTAssertFalse(
                element("map-paywall", in: app).exists,
                "reaching the policy must not have opened the paywall"
            )
        }
    }

    /// The paywall had exactly one entry point in the whole app, and a build
    /// without `Secrets.plist` disables it.
    ///
    /// `MapPaywallView` was reached only from a locked row in Map Tiles, and
    /// `providerRow` disables any source whose key did not resolve — which is
    /// every source in a build without the gitignored plist. An archive cut on
    /// a machine that lacks it therefore sells a subscription nobody can buy,
    /// and hides **Restore Purchases** from a subscriber reinstalling, since
    /// that button lives on the same screen.
    ///
    /// This build has the keys, so the disabled state cannot be reproduced
    /// here. What is asserted instead is the guarantee that makes it not
    /// matter: an entry point in the section that reads no entitlement, no
    /// product and no key. Tapped, rather than merely present — a row that
    /// opens nothing is the same dead end in a different place.
    @MainActor
    func testProIsReachableWithoutTheMapTilesSection() {
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
            "the About row should open the paywall, where Restore Purchases lives"
        )
    }

    /// The row is for buying, so a subscriber does not get it — they have
    /// *Manage Subscription* in Map Tiles, and `MapPaywallView` dismisses
    /// itself the moment the store answers, so opening it would flash a sheet
    /// shut in their face.
    @MainActor
    func testProRowIsAbsentForASubscriber() {
        let app = launchApp(arguments: ["--ui-test-entitled"])

        element("settings-button", in: app).tap()
        XCTAssertTrue(
            element("settings-screen", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        // Scrolled to the bottom first: absence asserted against a row that
        // was never drawn has to be told apart from one that is merely off
        // screen, and `terms-link` is the row it would sit beside.
        XCTAssertTrue(scrollIntoView(element("terms-link", in: app), in: app))
        XCTAssertFalse(
            element("about-pro-link", in: app).exists,
            "a subscriber has Manage Subscription instead"
        )
    }

    /// The switch itself rather than the row it sits in.
    ///
    /// SwiftUI pushes a `Form` row's identifier down onto the cell as well as
    /// onto the control, and an untyped lookup finds the cell first — which
    /// has no on/off value to read and, tapped, reports nothing back.
    @MainActor
    private func toggle(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.switches.matching(identifier: identifier).firstMatch
    }

    /// Taps the switch rather than the row's label.
    ///
    /// The element carrying the identifier spans the whole row — label
    /// included — and `tap()` lands in the middle of it, which for a SwiftUI
    /// `Toggle` in a `Form` is inert: only the control itself flips. So the
    /// tap is aimed at the trailing edge, where the control is.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle
            .coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .tap()
    }

    /// A SwiftUI `Toggle` reports its state as the string "0" or "1".
    @MainActor
    private func toggleIsOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    @MainActor
    private func waitUntilToggle(
        _ toggle: XCUIElement,
        is expected: Bool,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        waitUntil(timeout: timeout) { toggleIsOn(toggle) == expected }
    }
}
