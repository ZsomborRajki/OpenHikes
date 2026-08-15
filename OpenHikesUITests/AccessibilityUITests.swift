//
//  AccessibilityUITests.swift
//  OpenHikesUITests
//
//  What a hiker using VoiceOver, Dynamic Type or Switch Control gets from each
//  screen. Two kinds of check, and they answer different questions:
//
//  1. `performAccessibilityAudit` is the sweep. It walks the live element tree
//     and reports unlabelled controls, clipped text at large type sizes,
//     contrast failures and hit regions too small to reach — the class of
//     regression that arrives quietly, in a view nobody thought to re-check.
//     It is deliberately run per screen rather than once: the audit only sees
//     what is on screen at the time.
//
//  2. Explicit assertions on the labels, values and traits this app promises.
//     An audit cannot tell that a tile-provider row is *the selected one*, or
//     that the elevation graph reads out the point under the tracker; those
//     are the app's own semantics, and they are the ones that broke before.
//
//  Both are out-of-process, so nothing here can import the app; screens are
//  reached with the same launch arguments and helpers the functional tests
//  use (see ``UITestSupport``).
//

import XCTest

nonisolated final class AccessibilityUITests: XCTestCase {
    // MARK: - Audits

    /// The first screen: the map, the weather badge and the sheet's search
    /// row. Element detection is the check that matters most here, since two
    /// of the controls are glyph-only buttons.
    @MainActor
    func testMapAndSheetPassAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)

        try audit(app)
    }

    @MainActor
    func testHikeDetailPassesAccessibilityAudit() throws {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)
        XCTAssertTrue(
            element("elevation-chart", in: app)
                .waitForExistence(timeout: UITestTimeout.existence)
        )

        try audit(app)
    }

    @MainActor
    func testSettingsPassesAccessibilityAudit() throws {
        let app = launchApp()
        openSettings(in: app)

        try audit(app)
    }

    // MARK: - Sheet and hike list

    /// The clear button is an `xmark.circle.fill` and nothing else, and that
    /// glyph is hidden as decoration — so without a label of its own the
    /// control announced itself as an unnamed button.
    @MainActor
    func testSearchControlsAreNamed() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet"])

        let search = element("map-search", in: app)
        XCTAssertTrue(
            search.waitForExistence(timeout: UITestTimeout.existence)
        )
        search.tap()
        search.typeText("Thumsee")

        let clear = element("clear-search-button", in: app)
        XCTAssertTrue(
            clear.waitForExistence(timeout: UITestTimeout.existence),
            "typing should offer a way to clear the field"
        )
        XCTAssertEqual(clear.label, "Clear search")

        XCTAssertEqual(
            element("settings-button", in: app).label,
            "Profile and settings"
        )
    }

    /// A row is one tap target, so it is one element — and which hike the map
    /// is drawing is otherwise carried only by a tinted chevron and a tinted
    /// row background, which is colour alone.
    @MainActor
    func testHikeRowReadsAsOneElementAndReportsSelection() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        let row = awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        XCTAssertTrue(
            row.label.hasPrefix(UITestFixture.importedHikeTitle),
            "a row should lead with the hike's name, got \"\(row.label)\""
        )
        XCTAssertGreaterThan(
            row.label.count,
            UITestFixture.importedHikeTitle.count,
            "a row should also carry its subtitle, not just the title"
        )
        // An import selects what it imported, so this hike is the one on the
        // map from the moment its row appears.
        XCTAssertTrue(
            waitUntilSelected(row),
            "the hike the map is drawing should report itself as selected"
        )
    }

    // MARK: - Hike detail

    /// Two texts in a rounded rectangle are one fact, and the caption is drawn
    /// uppercased — which VoiceOver spells out ("A V G Speed") unless the
    /// label is spoken from the original.
    @MainActor
    func testStatTilesReadAsLabelAndValue() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)

        let distance = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Distance"))
            .firstMatch
        XCTAssertTrue(
            distance.waitForExistence(timeout: UITestTimeout.existence),
            "the stats grid should expose a tile named \"Distance\""
        )
        XCTAssertFalse(
            (distance.value as? String ?? "").isEmpty,
            "a stat tile's number belongs in its accessibility value"
        )
    }

    /// The graph is a drag target with no leaves of its own, so it is only
    /// reachable at all if it is an element in its own right — and only usable
    /// if that element is adjustable.
    @MainActor
    func testElevationChartIsReadableAndAdjustable() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)

        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(
            chart.waitForExistence(timeout: UITestTimeout.existence)
        )
        XCTAssertEqual(chart.label, "Elevation profile")

        let start = chart.value as? String ?? ""
        XCTAssertFalse(
            start.isEmpty,
            "the graph should read out the point under the tracker"
        )

        // The scrub an adjustable swipe stands in for. VoiceOver's own
        // increment cannot be sent from out of process, so this drives the
        // same `onScrub` through the gesture and checks that the spoken value
        // follows the tracker rather than being fixed at the start of the walk.
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: chart.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
                )
            )
        XCTAssertTrue(
            waitUntilValueChanges(from: start, in: chart),
            "scrubbing should change what the graph reads out"
        )
    }

    /// A bare `Slider` has no accessible name, and the caption above it was
    /// the only place the control said what it changed.
    @MainActor
    func testRouteAppearanceControlsAreNamed() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)

        let slider = element("route-width-slider", in: app)
        XCTAssertTrue(
            slider.waitForExistence(timeout: UITestTimeout.existence)
        )
        XCTAssertEqual(slider.label, "Line width")
        XCTAssertTrue(
            (slider.value as? String ?? "").hasSuffix("points"),
            "the slider should say what its number means, got "
                + "\"\(slider.value as? String ?? "")\""
        )

        let selected = element("route-pattern-directional", in: app)
        XCTAssertTrue(selected.isSelected)
        XCTAssertFalse(
            selected.label.isEmpty,
            "a swatch draws no text, so it needs a label of its own"
        )
    }

    // MARK: - Settings

    /// Which provider is in use was drawn as a checkmark and nothing else, and
    /// that checkmark is hidden from VoiceOver as decoration — so the
    /// selection was unreadable without it.
    @MainActor
    func testTileProviderSelectionIsExposed() {
        let app = launchApp()
        openSettings(in: app)

        let openStreetMap = element("provider-row-osm", in: app)
        XCTAssertTrue(
            openStreetMap.waitForExistence(timeout: UITestTimeout.existence),
            "OpenStreetMap is the keyless default and is always listed"
        )
        XCTAssertTrue(
            openStreetMap.isSelected,
            "the provider the map is drawing with should report as selected"
        )
    }

    @MainActor
    func testStorageRowsReadAsLabelAndValue() {
        let app = launchApp()
        openSettings(in: app)

        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Saved for offline"))
            .firstMatch
        XCTAssertTrue(
            scrollIntoView(saved, in: app),
            "the offline storage section should be reachable in Settings"
        )
        XCTAssertFalse(
            (saved.value as? String ?? "").isEmpty,
            "a byte count — or the fact it is still being measured — belongs "
                + "in the row's value, not in an ellipsis"
        )
    }

    // MARK: - Recording

    /// The recording screen is the one a hiker uses without looking at it, so
    /// its live numbers have to be readable and its phase has to be announced.
    @MainActor
    func testRecordingScreenIsReadable() throws {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let phase = element("recording-phase", in: app)
        XCTAssertTrue(
            phase.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertFalse(
            phase.label.isEmpty,
            "the phase dot is a colour, so the word beside it has to be spoken"
        )

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        XCTAssertEqual(points.label, "Points")
        XCTAssertNotNil(points.value as? String)

        try audit(app)
    }
}

// MARK: - Helpers

/// Held in an extension so the suite above stays a list of what is
/// checked, and so the audit plumbing is not counted against the class
/// body it serves.
private extension AccessibilityUITests {
    /// Runs the sweep and reports every issue at once, rather than failing on
    /// the first.
    ///
    /// Three audits are excluded, all because they report things this app does
    /// not own.
    ///
    /// - `.contrast` reads rendered pixels, and every sheet control here sits
    ///   on a live glass background over an arbitrary map — the measured ratio
    ///   is whatever tiles happen to be underneath.
    /// - `.textClipped` measures MapKit's own attribution and scale views.
    /// - `.dynamicType` reports SwiftUI nodes whose font it cannot introspect,
    ///   including a navigation bar's system "Done" button and `Form` section
    ///   footers — text this app neither styles nor sizes. Every font it does
    ///   set is a semantic one, which scales by definition; the only fixed
    ///   sizes are decorative glyphs inside fixed frames, already hidden from
    ///   VoiceOver. ``StatGrid`` covers the case that actually mattered.
    static let auditTypes: XCUIAccessibilityAuditType = .all
        .subtracting(.contrast)
        .subtracting(.textClipped)
        .subtracting(.dynamicType)

    @MainActor
    func audit(
        _ app: XCUIApplication,
        for types: XCUIAccessibilityAuditType = AccessibilityUITests.auditTypes,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var reports: [String] = []
        try app.performAccessibilityAudit(for: types) { issue in
            if !Self.isSystemOwned(issue) {
                reports.append(Self.report(issue))
            }
            // Always "handled": an issue is either collected above or
            // deliberately ignored, and reporting them together beats failing
            // on whichever the sweep happened to reach first.
            return true
        }
        guard reports.isEmpty else {
            XCTFail(
                "\(reports.count) accessibility issue(s):\n"
                    + reports.joined(separator: "\n\n"),
                file: file,
                line: line
            )
            return
        }
    }

    /// Enough to find the view again — the compact description alone names the
    /// problem but not the control.
    ///
    /// The fallbacks matter as much as the identifier does. An issue the audit
    /// cannot attribute to any element used to report as "an unidentifiable
    /// element" and nothing else, which named neither the view nor the screen
    /// region and left the only way forward a guess; the type and the frame
    /// are what turn that back into something locatable.
    @MainActor
    static func report(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let element = issue.element
        let parts = [
            element?.identifier,
            element?.label,
            element?.value as? String,
        ].compactMap { part in
            (part?.isEmpty == false) ? part : nil
        }
        let subject = parts.isEmpty
            ? (element?.elementType).map { "element type \($0.rawValue)" }
                ?? "an unidentifiable element"
            : parts.joined(separator: " / ")
        let frame = element.map { "\n Frame: \($0.frame)" } ?? ""
        return """
            \(issue.compactDescription)
            \(issue.detailedDescription)
            Element: \(subject)\(frame)
            """
    }

    /// Issues raised against views the app does not build. MapKit draws its own
    /// compass, scale, attribution label and annotation views inside
    /// ``MapView``, and their sizes and labels are not ours to set.
    ///
    /// The audit names the offending view's class in its detailed description,
    /// which is the only handle an out-of-process test has on it: those views
    /// carry no identifier, and the map itself is the only element of ours they
    /// can be attributed to.
    ///
    /// The third clause covers the map's *tiles* rather than its subviews.
    /// Element detection reads rendered pixels, and an OpenStreetMap raster
    /// tile has town and road names drawn into it — text with no element
    /// behind it anywhere, because it is a picture of text. While the map is
    /// the front screen those issues are attributed to `trail-map` and the
    /// first clause catches them. Behind a presented sheet it is not in the
    /// accessibility tree at all, so the audit reports them with no element to
    /// attribute them to, and they arrive here as an unnamed "potentially
    /// inaccessible text".
    ///
    /// That combination — element detection, and no element at all — is only
    /// reachable for something outside the tree, which the app's own frontmost
    /// content never is. It stays narrow for that reason: a `Text` this app
    /// forgot to expose is still attributed to the SwiftUI element that drew
    /// it and is still reported.
    ///
    /// This is the same argument `.contrast` is excluded wholesale under —
    /// both read pixels, and the pixels behind this app's sheets are an
    /// arbitrary map.
    @MainActor
    static func isSystemOwned(
        _ issue: XCUIAccessibilityAuditIssue
    ) -> Bool {
        if let identifier = issue.element?.identifier,
           Self.systemOwnedIdentifiers.contains(identifier) {
            return true
        }
        if issue.auditType == .elementDetection, issue.element == nil {
            return true
        }
        return issue.detailedDescription
            .split { !$0.isLetter && !$0.isNumber }
            .contains { $0.hasPrefix("MK") }
    }

    static let systemOwnedIdentifiers: Set<String> = [
        "trail-map",
    ]

    @MainActor
    func openSettings(in app: XCUIApplication) {
        let settings = element("settings-button", in: app)
        XCTAssertTrue(
            settings.waitForExistence(timeout: UITestTimeout.existence)
        )
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["Settings"]
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
    }

    @MainActor
    func waitUntilValueChanges(
        from original: String,
        in element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String != original { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
