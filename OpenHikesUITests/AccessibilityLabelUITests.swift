//
//  AccessibilityLabelUITests.swift
//  OpenHikesUITests
//
//  The labels, values and traits this app promises, asserted one control at a
//  time.
//
//  Separate from ``AccessibilityUITests`` because the audit cannot make any of
//  these checks: it can tell that a row is reachable and named, but not that
//  the name is the hike's, that the row is *the selected* one, or that the
//  elevation graph speaks the point under the tracker. Those are this app's
//  own semantics, and they are the ones that have actually broken.
//

import XCTest

nonisolated final class AccessibilityLabelUITests: XCTestCase {
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

    /// MetricKit reports nothing on a Simulator — `mxSignpost` attaches the
    /// literal `NO_METRICS` there — so the only state this can ever reach in
    /// automation is the empty one. That is worth asserting anyway: the empty
    /// state is what every user sees for the first day after installing, and
    /// a row whose value is blank would announce itself as the bare word
    /// "Reports" with nothing after it.
    @MainActor
    func testDeviceReportRowReadsAsLabelAndValue() {
        let app = launchApp()
        openSettings(in: app)

        let reports = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Reports"))
            .firstMatch
        XCTAssertTrue(
            scrollIntoView(reports, in: app),
            "the device reports section should be reachable in Settings"
        )
        XCTAssertFalse(
            (reports.value as? String ?? "").isEmpty,
            "whether a report exists yet belongs in the row's value, not in "
                + "an empty row the reader has to interpret"
        )
    }

    /// The map's own glass controls, which MapKit hosts and this app builds by
    /// hand in UIKit — so none of SwiftUI's labelling applies to them.
    @MainActor
    func testMapPhotoControlsAreNamed() {
        let app = launchApp(
            arguments: [
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        openHikeDetail(in: app)

        let camera = element("map-camera-button", in: app)
        XCTAssertTrue(
            camera.waitForExistence(timeout: UITestTimeout.existence),
            "opening a hike should offer the camera pill"
        )
        XCTAssertEqual(camera.label, "Take a photo of this trail")
        XCTAssertEqual(
            element("map-photo-library-button", in: app).label,
            "Add a photo from your library"
        )
    }
}
