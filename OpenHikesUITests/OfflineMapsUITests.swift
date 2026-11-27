//
//  OfflineMapsUITests.swift
//  OpenHikesUITests
//
//  *Offline Maps* as a hiker reaches it — from *Map Modes*, from Settings and
//  from a hike's *Offline* tile — up to the moment a download would start,
//  and no further.
//
//  Against ``SeededOfflineCountryServer``'s ten areas, which a launch asks
//  for by name. Only the list is stood in for: the launch keeps no download
//  session, so nothing here downloads, and nothing pretends to. Each test
//  stops at the last screen that is true of a real launch — a row that
//  offers *Download*, or the tile's dialog naming the country and its size —
//  and never taps the download itself. What each order and a search do to
//  the list is `OfflineCountryDirectoryTests`'s; this is about the screen.
//
//  Every step keeps a screenshot in the result bundle, so a run can be looked
//  at as well as read.
//

import XCTest

nonisolated final class OfflineMapsUITests: XCTestCase {
    /// The list by name, from *Map Modes*: the head that says which map the
    /// downloads are for, a section a letter, and the United States, which is
    /// split, opening to its states.
    @MainActor
    func testOfflineMapsListsTheCountriesByName() {
        let app = launchApp(arguments: OfflineMapsFixture.seededArguments)
        openMapModes(in: app)
        let row = element("map-modes-offline-maps", in: app)
        scrollIntoView(row, in: app)
        keepScreenshot("1 Map Modes, with Offline Maps at its foot", of: app)
        row.tap()

        let austria = element("offline-country-AT", in: app)
        XCTAssertTrue(austria.waitForExistence(timeout: UITestTimeout.navigation), "the seeded list should load")
        XCTAssertEqual(
            element("offline-maps-order-button", in: app).value as? String,
            "Name",
            "with no position, the list opens by name"
        )
        XCTAssertTrue(app.staticTexts["Downloads are for the OpenHikes map only."].exists)
        XCTAssertTrue(app.switches.matching(identifier: "offline-maps-extra-detail").firstMatch.exists)
        XCTAssertTrue(app.switches.matching(identifier: "offline-maps-elevation-data").firstMatch.exists)
        keepScreenshot("2 Offline Maps at the sheet's middle, over the map", of: app)

        raiseSheet(in: app)
        XCTAssertTrue(sectionHeader("G", in: app).exists, "by name, each country is under its letter")
        keepScreenshot("3 the whole list by name, with its letters down the edge", of: app)

        let unitedStates = element("offline-country-group-US", in: app)
        XCTAssertTrue(scrollUntilVisible(unitedStates, in: app), "the split country should be listed")
        expectLabel(unitedStates, contains: "3 regions", "a split country says how many regions it holds")
        unitedStates.tap()
        let colorado = element("offline-country-US-CO", in: app)
        XCTAssertTrue(colorado.waitForExistence(timeout: UITestTimeout.navigation), "opening it shows its states")
        XCTAssertTrue(
            colorado.label.hasPrefix("Colorado"),
            "a state under its country is named alone: \(colorado.label)"
        )
        XCTAssertTrue(
            scrollUntilVisible(element("offline-country-US-WY", in: app), in: app),
            "and the other states under it"
        )
        keepScreenshot("4 the United States opened to its states", of: app)
    }

    /// A search narrows the list as it is typed: a name that starts with
    /// what is typed before one that only holds it, a region found by its
    /// country's name, and a name nothing answers.
    @MainActor
    func testSearchingNarrowsTheList() {
        let app = launchApp(arguments: OfflineMapsFixture.seededArguments)
        openOfflineMaps(in: app)
        let field = element("offline-maps-search", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: UITestTimeout.navigation))
        field.tap()
        field.typeText("wa")

        let washington = element("offline-country-US-WA", in: app)
        let norway = element("offline-country-NO", in: app)
        XCTAssertTrue(washington.waitForExistence(timeout: UITestTimeout.navigation), "Washington starts with it")
        XCTAssertTrue(norway.exists, "Norway holds it")
        XCTAssertLessThan(washington.frame.minY, norway.frame.minY, "a name that starts with it comes first")
        XCTAssertTrue(
            waitUntil { !self.element("offline-country-AT", in: app).exists },
            "Austria answers nothing typed"
        )
        XCTAssertFalse(
            element("offline-maps-order-button", in: app).exists,
            "the order steps aside while the field has the keyboard"
        )
        keepScreenshot("5 a search for “wa”: Washington, then Norway", of: app)

        tapWhenReady(element("offline-maps-clear-search", in: app))
        field.typeText("united")
        let colorado = element("offline-country-US-CO", in: app)
        XCTAssertTrue(colorado.waitForExistence(timeout: UITestTimeout.navigation), "a state answers to its country")
        expectLabel(colorado, contains: "Colorado, United States", "a state found alone is named with its country")
        XCTAssertTrue(element("offline-country-US-WY", in: app).exists)
        keepScreenshot("6 a search for “united”: the three states", of: app)

        tapWhenReady(element("offline-maps-clear-search", in: app))
        field.typeText("Atlantis")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Atlantis")).firstMatch
                .waitForExistence(timeout: UITestTimeout.navigation),
            "a search that finds nothing says so, with what was asked"
        )
        XCTAssertFalse(washington.exists)
        keepScreenshot("7 a search for “Atlantis”: no results", of: app)
    }

    /// The capsule beside the field offers the orders, and each puts another
    /// country first: by name Austria, largest first France.
    @MainActor
    func testTheOrderCapsulePutsAnotherCountryFirst() {
        let app = launchApp(arguments: OfflineMapsFixture.seededArguments)
        openOfflineMaps(in: app)
        XCTAssertTrue(element("offline-country-AT", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        raiseSheet(in: app)

        choose("Largest", in: app)
        XCTAssertTrue(sectionHeader("All Countries", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        assertListed("FR", above: "DE", in: app, "largest first, France leads")
        keepScreenshot("8 largest first: France, then Germany", of: app)

        choose("Name", in: app)
        XCTAssertTrue(sectionHeader("A", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        assertListed("AT", above: "FR", in: app, "by name, Austria leads")
        keepScreenshot("9 by name again: Austria first", of: app)
    }

    /// With the hiker's position the list opens nearest first, and *Nearby*
    /// holds the country underfoot ahead of its neighbour.
    @MainActor
    func testTheListOpensNearestTheHiker() {
        let app = makeApp(arguments: OfflineMapsFixture.seededArguments + ["--ui-test-enable-location"])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        defer { XCUIDevice.shared.location = nil }
        launch(app)
        answerLaunchPrompt(in: app)

        openOfflineMapsWithAPosition(in: app)
        raiseSheet(in: app)
        XCTAssertTrue(sectionHeader("Nearby", in: app).exists, "nearest first, the areas within reach have a heading")
        assertListed("DE", above: "AT", in: app, "the Thumsee trailhead is in Germany, a few kilometres from Austria")
        keepScreenshot("10 nearest the Thumsee trailhead: Germany, then Austria", of: app)

        tapWhenReady(element("offline-maps-order-button", in: app))
        XCTAssertTrue(
            app.buttons["Nearest"].waitForExistence(timeout: UITestTimeout.navigation),
            "with a position, nearest first is one of the orders"
        )
        keepScreenshot("11 the order capsule's menu", of: app)
        app.buttons["Nearest"].tap()
    }

    /// *Extra Detail* changes what every download costs, and a row shows
    /// its country on the map and offers its download. The download itself
    /// is where this stops.
    @MainActor
    func testChoosingACountryShowsItAndOffersItsDownload() {
        let app = launchApp(arguments: OfflineMapsFixture.seededArguments)
        openOfflineMaps(in: app)
        let austria = element("offline-country-AT", in: app)
        XCTAssertTrue(austria.waitForExistence(timeout: UITestTimeout.navigation))

        // Flipped while the list is at its head: scrolled, the switch slides
        // under the search field, and a tap there lands on the field.
        let sized = austria.label
        let extraDetail = app.switches.matching(identifier: "offline-maps-extra-detail").firstMatch
        XCTAssertEqual(extraDetail.value as? String, "1", "Extra Detail is on until it is turned off")
        extraDetail.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(
            waitUntilLabelChanges(from: sized, on: austria),
            "without Extra Detail a download costs less, and the row says so: \(sized)"
        )
        keepScreenshot("12 Extra Detail off: \(austria.label), from \(sized)", of: app)

        scrollIntoView(austria, in: app)
        XCTAssertTrue(
            app.buttons["Download Austria"].exists,
            "a country not yet downloaded offers its download beside it"
        )
        austria.tap()
        XCTAssertTrue(waitUntilSelected(austria), "the tapped country becomes the chosen one")
        keepScreenshot("13 Austria chosen: its row tinted and the map moved to it", of: app)
        XCTAssertTrue(app.buttons["Download Austria"].exists, "nothing started downloading")
        XCTAssertFalse(app.buttons["Cancel Download"].exists)
    }

    /// The same list in Settings, beside the storage it costs, where it has
    /// no map to show a country on.
    @MainActor
    func testSettingsListsTheSameCountries() {
        let app = launchApp(arguments: OfflineMapsFixture.seededArguments)
        openSettings(in: app)
        let row = element("settings-offline-maps", in: app)
        XCTAssertTrue(scrollUntilVisible(row, in: app), "Settings' storage section holds Offline Maps")
        keepScreenshot("14 Settings, with Offline Maps beside the storage it takes", of: app)
        row.tap()

        XCTAssertTrue(app.navigationBars["Offline Maps"].waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(element("offline-country-AT", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(app.buttons["Download Austria"].exists)
        keepScreenshot("15 Offline Maps in Settings", of: app)
    }

    /// A hike's *Offline* tile on the OpenHikes map offers the countries its
    /// trail crosses — Germany alone for the Thumsee loop — with what each
    /// costs, in a dialog that is the last step before a download.
    @MainActor
    func testTheHikeScreenOffersTheCountryItsTrailCrosses() {
        let app = launchApp(
            arguments: OfflineMapsFixture.seededArguments + ["--ui-test-import-gpx=\(UITestFixture.gpxName)"]
        )
        openHikeDetail(in: app)
        let tile = element("offline-country-button", in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: UITestTimeout.navigation), "the OpenHikes map offers the tile")
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { tile.isEnabled },
            "the tile is enabled once it has found the countries the trail crosses"
        )
        scrollIntoView(tile, in: app)
        keepScreenshot("16 the hike screen's Offline tile", of: app)
        tile.tap()

        let germany = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download Germany")).firstMatch
        XCTAssertTrue(germany.waitForExistence(timeout: UITestTimeout.navigation), "the trail is in Germany")
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download Austria")).firstMatch.exists,
            "and in no other country"
        )
        keepScreenshot("17 the tile's dialog: Germany, and what it costs", of: app)
        dismissDialog(in: app)
        XCTAssertTrue(waitUntil { !germany.exists }, "the dialog goes without downloading")
        XCTAssertEqual(tile.value as? String, "Not saved")
    }

    /// The copy a hiker reads when the list cannot be fetched, and the way
    /// to ask again.
    @MainActor
    func testAListThatCannotLoadOffersToTryAgain() {
        let app = launchApp(arguments: OfflineMapsFixture.refusedArguments)
        openOfflineMaps(in: app)
        XCTAssertTrue(
            app.staticTexts["Couldn’t Load Countries"].waitForExistence(timeout: UITestTimeout.navigation),
            "a list that cannot load says so"
        )
        XCTAssertTrue(app.buttons["Try Again"].exists, "and offers to ask again")
        keepScreenshot("18 a list that could not load", of: app)
    }
}

// MARK: - Steps

private extension OfflineMapsUITests {
    /// Drags the sheet to its full height, where the list has room for its
    /// letters, and waits for it to settle there.
    @MainActor
    func raiseSheet(in app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        XCTAssertTrue(grabber.waitForExistence(timeout: UITestTimeout.navigation), "the sheet offers a grabber")
        grabber.coordinate(withNormalizedOffset: Self.middle)
            .press(forDuration: Self.dragPress, thenDragTo: app.coordinate(withNormalizedOffset: Self.screenTop))
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(
            waitUntil { sheet.exists && sheet.frame.minY < app.frame.height * Self.raisedSheetFraction },
            "the sheet should come to rest at its full height"
        )
    }

    /// Opens the list, and again until it has the hiker's position: the list
    /// reads it once as it comes up, and the first fix can land after that.
    @MainActor
    func openOfflineMapsWithAPosition(in app: XCUIApplication) {
        let order = element("offline-maps-order-button", in: app)
        let hasPosition = waitUntil(timeout: UITestTimeout.trace) {
            openOfflineMaps(in: app)
            if waitUntil(timeout: UITestTimeout.brief, { (order.value as? String) == "Nearest" }) { return true }
            popScreen(in: app)
            return false
        }
        XCTAssertTrue(hasPosition, "with the hiker's position, the list should open nearest first")
    }

    /// Picks `order` from the capsule's menu.
    @MainActor
    func choose(_ order: String, in app: XCUIApplication) {
        let capsule = element("offline-maps-order-button", in: app)
        tapWhenReady(capsule)
        tapWhenReady(app.buttons[order])
        XCTAssertTrue(
            waitUntil { (capsule.value as? String) == order },
            "the capsule should say the order chosen, and said \(String(describing: capsule.value))"
        )
    }

    @MainActor
    func assertListed(
        _ upper: String,
        above lower: String,
        in app: XCUIApplication,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let first = element("offline-country-\(upper)", in: app)
        let second = element("offline-country-\(lower)", in: app)
        XCTAssertTrue(
            first.waitForExistence(timeout: UITestTimeout.navigation) && second.exists,
            "both rows should be listed — \(message)",
            file: file,
            line: line
        )
        XCTAssertLessThan(first.frame.minY, second.frame.minY, message, file: file, line: line)
    }

    /// A section's heading, however the list cases it.
    @MainActor
    func sectionHeader(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", title)).firstMatch
    }

    /// Closes a confirmation dialog without choosing anything in it: by its
    /// Cancel where it is an action sheet, or by a tap outside it where it is
    /// a popover.
    @MainActor
    func dismissDialog(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: Self.screenTop).tap()
        }
    }

    static let middle = CGVector(dx: 0.5, dy: 0.5)
    static let screenTop = CGVector(dx: 0.5, dy: 0.08)
    static let dragPress: TimeInterval = 0.1
    /// Above this share of the screen's height, the sheet is at its full one.
    static let raisedSheetFraction: CGFloat = 0.2
}
