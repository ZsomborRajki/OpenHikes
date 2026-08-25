//
//  OpenHikesUITests.swift
//  OpenHikesUITests
//
//  The map, the sheet and a hike's own screen — the app driven the way
//  someone browsing their walks drives it. Recording lives in
//  ``RecordingUITests``, photos in ``PhotoUITests``, settings and diagnostics
//  in ``SettingsUITests``, and everything spoken in ``AccessibilityUITests``.
//  Fixtures, launch helpers and location plumbing are shared through
//  `UITestSupport.swift`.
//

import CoreLocation
import XCTest

nonisolated final class OpenHikesUITests: XCTestCase {
    @MainActor
    func testLaunchesMapAndOpensSettings() {
        let app = launchApp()

        XCTAssertTrue(
            element("trail-map", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(element("map-search", in: app).exists)

        element("settings-button", in: app).tap()
        XCTAssertTrue(
            app.navigationBars["Settings"]
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(element("settings-screen", in: app).exists)
        app.buttons["Done"].tap()
    }

    @MainActor
    func testImportsBundledGPXAndOpensItsDetails() {
        let app = launchApp(
            arguments: ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )

        openHikeDetail(in: app)
    }

    /// The GPX importer has to hang off the sheet for the same reason the
    /// photo picker does, and fails the same silent way if it doesn't.
    ///
    /// This is the presentation the rule was learned from: a `.fileImporter`
    /// attached beside a sheet that is never dismissed is never presented, and
    /// says nothing about it — the Import button simply stops working. Nothing
    /// but automation notices that.
    @MainActor
    func testOpensAndClosesTheGPXImporterOverTheSheet() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet"])

        let importButton = element("import-gpx-button", in: app)
        XCTAssertTrue(
            importButton.waitForExistence(timeout: UITestTimeout.navigation)
        )
        importButton.tap()

        // The document browser is another process, so its listing is not the
        // app's to assert on — that it is up, and that leaving it puts the app
        // back the way it was, is the whole of the contract being checked.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(
            cancel.waitForExistence(timeout: UITestTimeout.existence),
            "tapping Import GPX should present the document picker"
        )

        cancel.tap()
        XCTAssertTrue(
            element("map-sheet", in: app)
                .waitForExistence(timeout: UITestTimeout.navigation),
            "dismissing the importer must leave the app's sheet standing"
        )
        XCTAssertTrue(
            element("record-hike-button", in: app).exists,
            "and the sheet must still be the one that offers its own controls"
        )
    }

    /// Deleting a hike from underneath its own detail view.
    ///
    /// The delete does three things that are easy to get wrong separately: it
    /// removes the row, it clears the selection so the map stops drawing a
    /// trail that no longer exists, and it pops the detail view so nothing is
    /// left writing to a detached model. The third is the one with no visible
    /// symptom until something writes.
    @MainActor
    func testDeletingAHikeClearsItsScreenAndItsRow() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        openHikeDetail(in: app)
        popScreen(in: app)

        let row = awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        XCTAssertTrue(
            waitUntilSelected(row),
            "opening a hike should leave it the selected one"
        )

        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: UITestTimeout.navigation),
            "swiping a row should reveal its delete action"
        )
        delete.tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: UITestTimeout.existence)
        XCTAssertFalse(
            app.navigationBars[UITestFixture.importedHikeTitle].exists,
            "deleting the selected hike must not leave its detail view pushed"
        )
    }

    /// Renaming reaches the list, not just the header it was typed into.
    ///
    /// The title is stored as a `customName` the row reads back through its
    /// own combined label, so a rename that draws correctly on the detail
    /// screen and not in the sheet is a plausible failure with two places to
    /// look. This checks both from one edit.
    @MainActor
    func testRenamingAHikeUpdatesItsRow() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        openHikeDetail(in: app)
        app.buttons["Rename hike"].tap()

        let field = element("hike-title-field", in: app)
        XCTAssertTrue(
            field.waitForExistence(timeout: UITestTimeout.navigation),
            "the rename button should swap the title for a field"
        )
        field.tap()
        // The field opens holding the current title, so the new name has to
        // replace it rather than be appended to it.
        field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        field.typeText(Self.renamedHikeName)
        commitKeyboardEdit(in: app)

        XCTAssertTrue(
            app.navigationBars[Self.renamedHikeName]
                .waitForExistence(timeout: UITestTimeout.navigation),
            "committing the edit should retitle the screen"
        )

        popScreen(in: app)
        awaitHikeRow(titled: Self.renamedHikeName, in: app)
        XCTAssertFalse(
            hikeRow(titled: UITestFixture.importedHikeTitle, in: app).exists,
            "the old name should not be left behind in the list"
        )
    }

    /// Search narrows the app's own hikes before it asks MapKit anything.
    ///
    /// The field is a plain `TextField` rather than `.searchable`, so nothing
    /// about the filtering is the system's: the "Your Hikes" section, its
    /// ordering ahead of Maps results, and the clear button that puts the list
    /// back are all this app's, and all only reachable by typing.
    @MainActor
    func testSearchFiltersOwnHikesAndClearingRestoresTheList() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)

        let search = element("map-search", in: app)
        XCTAssertTrue(
            search.waitForExistence(timeout: UITestTimeout.navigation)
        )
        search.tap()
        search.typeText(Self.searchTerm)

        XCTAssertTrue(
            app.staticTexts["Your Hikes"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "a matching hike should be offered above any map suggestion"
        )
        awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)

        let clear = element("clear-search-button", in: app)
        XCTAssertTrue(clear.exists, "a non-empty query should offer a way out")
        clear.tap()

        let cleared = NSPredicate(format: "exists == false")
        expectation(for: cleared, evaluatedWith: app.staticTexts["Your Hikes"])
        waitForExpectations(timeout: UITestTimeout.existence)
        awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
    }

    /// A hike's line pattern is picked from five swatches that draw no text,
    /// and each is addressed by its own identifier — SwiftUI pushes a
    /// container's identifier down onto every descendant, which would leave
    /// all five answering to one name.
    @MainActor
    func testPicksARouteLinePattern() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )

        openHikeDetail(in: app)

        let directional = element("route-pattern-directional", in: app)
        let dotted = element("route-pattern-dotted", in: app)
        XCTAssertTrue(
            directional.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(
            directional.isSelected,
            "a hike starts on the line-with-arrows it has always been drawn as"
        )

        scrollToTap(dotted, in: app)
        XCTAssertTrue(
            waitUntilSelected(dotted),
            "tapping a swatch should move the selection to it"
        )
        XCTAssertFalse(directional.isSelected)
    }

    /// The Surface and Difficulty sections, which are drawn only once
    /// OpenStreetMap has answered for a route.
    ///
    /// `--ui-test-trail-graph` supplies that answer from a bundled fixture, so
    /// what is under test is the app's analysis and its bars rather than
    /// Overpass's availability. The bars carry their shares as spoken values,
    /// which is both the assertion and the thing VoiceOver reads.
    @MainActor
    func testShowsSurfaceAndDifficultyForAMatchedRoute() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-trail-graph="
                    + UITestTrailTagFixture.trailGraphName,
            ]
        )

        openHikeDetail(in: app)

        // Both sections are built lazily and appear only once the analysis
        // finishes, so this has to keep looking rather than wait in place.
        let surface = element("surface-bar", in: app)
        XCTAssertTrue(
            scrollUntilVisible(surface, in: app, timeout: Self.analysisTimeout),
            "a route matched against tagged ways should report its surfaces"
        )
        XCTAssertTrue(
            (surface.value as? String)?
                .contains(UITestTrailTagFixture.spokenSurface) ?? false,
            "the surface bar should speak the shares it draws"
        )

        let difficulty = element("difficulty-bar", in: app)
        XCTAssertTrue(
            scrollUntilVisible(difficulty, in: app, timeout: Self.analysisTimeout)
        )
        XCTAssertTrue(
            (difficulty.value as? String)?
                .contains(UITestTrailTagFixture.spokenDifficulty) ?? false,
            "the difficulty bar should speak its SAC grades"
        )
    }

    /// The weather badge, stubbed because WeatherKit needs a network, a
    /// signed entitlement and real weather to agree with a test.
    ///
    /// What the stub replaces is the forecast; the badge, its glass and its
    /// spoken value are the shipping ones, and the value is where the number
    /// and the condition are actually put into words.
    @MainActor
    func testShowsTheWeatherBadge() {
        let app = launchApp(arguments: ["--ui-test-weather"])

        let badge = element("weather-badge", in: app)
        XCTAssertTrue(
            badge.waitForExistence(timeout: UITestTimeout.existence),
            "a forecast should be drawn over the map"
        )
        XCTAssertEqual(badge.label, "Current weather")
        let spoken = badge.value as? String
        XCTAssertTrue(
            spoken?.contains(Self.stubbedWeatherCondition) ?? false,
            "the badge should speak the condition beside its temperature"
        )
        XCTAssertTrue(
            spoken?.contains(Self.stubbedWeatherUnit) ?? false,
            "and should spell the unit out rather than leaving a bare number"
        )
    }

    @MainActor
    func testLaunchPerformance() {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.launchIterations

        measure(
            metrics: [XCTApplicationLaunchMetric()],
            options: options
        ) {
            makeApp().launch()
        }
    }

    /// Route analysis is off-main and unhurried; a launch measurement wants
    /// enough iterations to mean something without tripling the suite.
    private static let analysisTimeout: TimeInterval = 25
    private static let launchIterations = 3
    private static let renamedHikeName = "Renamed Route"
    private static let searchTerm = "Thumsee"
    /// `WeatherSnapshot.uiTestFixture`, spelled the way the badge speaks it.
    /// The unit is checked without its number: the badge draws Celsius, but
    /// the spoken value is formatted for the device's locale, which may put
    /// the same reading in Fahrenheit.
    private static let stubbedWeatherCondition = "Partly Cloudy"
    private static let stubbedWeatherUnit = "degrees"
}
