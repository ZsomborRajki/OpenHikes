//
//  SettingsUITests.swift
//  OpenHikesUITests
//
//  The settings screen and what it governs: which tile provider is in use and
//  what that provider is allowed to do, the two toggles that outlive the
//  screen they are set on, and the device reports iOS files against the app.
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
        scrollIntoView(element("route-width-slider", in: app), in: app)
        XCTAssertFalse(
            element("offline-download-button", in: app).exists,
            "a provider that forbids bulk download must not offer the button"
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
        scrollIntoView(photos, in: app)
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

        scrollIntoView(photos, in: app)
        XCTAssertEqual(
            toggleIsOn(photos),
            !photosBefore,
            "a toggle's value should survive its screen being rebuilt"
        )
    }

    /// The device-report screens, seeded because MetricKit never delivers on a
    /// Simulator — `mxSignpost` is inert there, so these three screens have
    /// been unreachable from automation since they shipped.
    ///
    /// Seeding writes through the real ``FieldMetricsStore`` into a directory
    /// of this launch's own, so the reports are read back by the shipping
    /// loader and no run inherits another's.
    @MainActor
    func testReadsExportsAndDeletesSeededFieldReports() {
        let app = launchApp(arguments: ["--ui-test-seed-metrics=2"])

        element("settings-button", in: app).tap()
        let report = element("field-metrics-report-row", in: app)
        XCTAssertTrue(
            scrollIntoView(report, in: app),
            "a seeded report should be listed under Device Reports"
        )
        report.tap()
        XCTAssertTrue(
            element("field-metrics-report-screen", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "tapping a report should open it"
        )
        popScreen(in: app)

        let export = element("field-metrics-export-link", in: app)
        XCTAssertTrue(scrollIntoView(export, in: app))
        export.tap()
        XCTAssertTrue(
            element("field-metrics-export-screen", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(
            element("field-metrics-share-button", in: app)
                .waitForExistence(timeout: Self.exportTimeout),
            "the archive should finish preparing and offer itself to share"
        )

        element("field-metrics-delete-button", in: app).tap()
        popScreen(in: app)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: report)
        // The link out to the share screen is drawn only when there is
        // something to share, so it going with them is the other half of it.
        expectation(for: gone, evaluatedWith: export)
        waitForExpectations(timeout: UITestTimeout.existence)
    }

    /// Writing the diagnostics archive is off-main and unhurried.
    private static let exportTimeout: TimeInterval = 25

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
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if toggleIsOn(toggle) == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
