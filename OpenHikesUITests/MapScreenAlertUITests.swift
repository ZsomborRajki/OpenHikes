//
//  MapScreenAlertUITests.swift
//  OpenHikesUITests
//
//  That an alert on the map screen can be raised at all, and that raising one
//  leaves the sheet where it was.
//
//  Both halves are the bug. `OpenHikesView` keeps `MapSheet` presented
//  permanently, and the alerts used to be attached to the view presenting it —
//  so a SwiftUI alert had nowhere to go. Raised while the sheet was settled it
//  opened and took the sheet down for the rest of the launch: no search field,
//  no hikes, and no gesture that brought either back. Raised while the sheet
//  was still going up it never appeared at all, which is why the first failure
//  went unreported for so long — a swallowed alert leaves nothing behind.
//
//  Reported by the user 2026-09-20: taking location access away in Settings,
//  coming back, and tapping the map's location button left a bare map.
//
//  Neither is a state a unit test can reach. What went wrong is which view a
//  presentation was attached to, and only a running app resolves that.
//

import XCTest

nonisolated final class MapScreenAlertUITests: XCTestCase {
    /// A launch with no location access shows the stand-in location button,
    /// which explains itself rather than spinning — and the sheet outlives
    /// the explanation.
    ///
    /// Tapped repeatedly on purpose: that is the hiker's own reproduction,
    /// and a second tap arriving while the first alert is presenting is
    /// exactly the race a single tap can miss.
    @MainActor
    func testTheLocationAlertLeavesTheSheetUp() {
        let app = launchApp()
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(
            sheet.waitForExistence(timeout: UITestTimeout.navigation),
            "the sheet should be up before anything is tapped"
        )

        let refused = element("location-access-refused", in: app)
        XCTAssertTrue(
            refused.waitForExistence(timeout: UITestTimeout.navigation),
            "a launch with no location access should show the stand-in button"
        )
        for _ in 0..<Self.rapidTaps {
            refused.tap()
            XCTAssertTrue(
                sheet.exists,
                "the sheet should still be up while the alert is being raised"
            )
        }

        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "the button should say why it can't do anything"
        )
        alert.buttons["Not Now"].tap()

        XCTAssertTrue(
            waitUntil { sheet.exists },
            "and the sheet should still be there once the alert is dismissed"
        )
    }

    /// A place card leaves the map live behind it, the refused location
    /// button included, and the map sheet is already presenting the card.
    /// The alert asked for from under it waited, and came up only once the
    /// card was closed, over a map the hiker had moved on from (#1403).
    @MainActor
    func testTheLocationAlertOpensOverAPlaceCard() {
        let app = launchApp(arguments: PlaceFixture.aroundArguments)
        let card = openFoundPlaceCard(in: app)

        answerTheLocationAlert(in: app)
        XCTAssertTrue(card.exists, "the card should still be up under it")

        app.buttons["places-around-card-close"].tap()
        XCTAssertTrue(waitUntil { !card.exists })
        // An alert that had queued behind the card comes up only once the
        // card has finished going, so this waits out that much.
        XCTAssertFalse(
            app.alerts.firstMatch.waitForExistence(timeout: UITestTimeout.brief),
            "closing the card should bring nothing back"
        )
    }

    /// The trail maker's place card is the other card that leaves the map
    /// live, and puts the alert up over itself the same way.
    @MainActor
    func testTheLocationAlertOpensOverTheMakersPlaceCard() {
        let app = launchApp()
        let card = openMakersPlaceCard(in: app)

        answerTheLocationAlert(in: app)
        XCTAssertTrue(card.exists, "the card should still be up under it")
    }

    /// Taps the refused location button and answers the alert it raises.
    @MainActor
    private func answerTheLocationAlert(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapWhenReady(element("location-access-refused", in: app), file: file, line: line)
        let alert = app.alerts["Location Access Off"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "the button should say why it can't do anything, over the card",
            file: file,
            line: line
        )
        alert.buttons["Not Now"].tap()
        XCTAssertTrue(waitUntil { !alert.exists }, "Not Now should close the alert", file: file, line: line)
    }

    /// A file that couldn't be read is reported. It used to be swallowed:
    /// the alert was raised while the sheet was going up, and never opened.
    @MainActor
    func testAnUnreadableImportIsReported() {
        let app = launchApp(arguments: ["--ui-test-import-gpx=NoSuchFixture"])
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: UITestTimeout.navigation))

        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "a file that couldn't be read should say so rather than vanish"
        )
        alert.buttons["OK"].tap()

        XCTAssertTrue(
            waitUntil { sheet.exists },
            "and the sheet should have survived the report"
        )
    }

    /// A file with two tracks asks which to import, from inside the sheet's
    /// contents like every other modal here — a sheet attached beside the
    /// permanent one would never open, and the import would wait forever on
    /// a question nobody could see.
    @MainActor
    func testAMultiTrackImportAsksWhichTracks() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=ThumseeTwoDays"])
        let importButton = element("gpx-track-choice-import", in: app)
        XCTAssertTrue(
            importButton.waitForExistence(timeout: UITestTimeout.navigation),
            "a file with two tracks should ask which to import"
        )
        let second = element("gpx-track-1", in: app)
        XCTAssertTrue(second.waitForExistence(timeout: UITestTimeout.existence))
        second.tap()
        importButton.tap()

        XCTAssertTrue(
            awaitHikeRow(titled: "Thumsee Day 1", in: app).exists,
            "the ticked track should become a hike"
        )
        XCTAssertFalse(hikeRow(titled: "Thumsee Day 2", in: app).exists, "and the unticked one should not")
        XCTAssertTrue(element("map-sheet", in: app).exists, "and the sheet should have survived the question")
    }

    /// A one-track file with one place more than an import keeps asks
    /// nothing, so the import says afterwards what it left out (#1076) — and
    /// says it from inside the sheet's contents, where an alert can open.
    @MainActor
    func testAnImportPastThePlaceCapSaysWhatItLeftOut() {
        let app = launchApp(arguments: ["--ui-test-expanded-sheet", "--ui-test-import-gpx=ThumseeCrowdedPlaces"])
        let alert = app.alerts["Not Every Place Was Imported"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "a hike kept without every place should say so rather than look complete"
        )
        let message = "1 more place lies on this track but wasn’t imported, "
            + "because one file can bring only so many."
        XCTAssertTrue(alert.staticTexts[message].exists, "and say how many, in the confirmation's words")
        alert.buttons["OK"].tap()

        XCTAssertTrue(
            awaitHikeRow(titled: "Thumsee Crowded Places", in: app).exists,
            "the hike itself should still have been imported"
        )
        XCTAssertTrue(element("map-sheet", in: app).exists, "and the sheet should have survived the notice")
    }

    /// A deletion the store refused says so. It used to say nothing: the hike
    /// stayed in the list, which is the right answer for the list, and the
    /// hiker was left with a *Delete* that had changed nothing. The alert is
    /// raised from the list's own question, in the moment that question is
    /// being dismissed, so this also checks that it is not lost to it.
    @MainActor
    func testARefusedDeletionIsReported() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-refuse-hike-deletion",
            ]
        )
        let row = awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: UITestTimeout.navigation),
            "swiping a row should reveal its delete action"
        )
        delete.tap()
        confirmDestructive(
            "Delete Hike",
            in: app,
            failureMessage: "deleting a hike should ask first"
        )

        let alert = app.alerts["Couldn’t Delete Hike"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "a deletion the store refused should say so rather than do nothing"
        )
        alert.buttons["OK"].tap()

        XCTAssertTrue(
            awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app).exists,
            "and the hike should still be in the list"
        )
        XCTAssertTrue(element("map-sheet", in: app).exists, "and the sheet should have survived the alert")
    }

    /// A hiker who has left the trail they are walking is asked what they
    /// mean by it, from inside the sheet's contents like every other alert
    /// here. *Keep Following* is the answer that changes nothing: the walk is
    /// still under way on its trail, and the sheet is where it was.
    ///
    /// The walk and its two minutes off the trail are a launch fixture — see
    /// `SeededWalkFixture` — because what is being checked is the answer.
    @MainActor
    func testKeepingToTheTrailLeavesTheWalkUnderWay() {
        let app = launchApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-walks=LeftTrail",
            ]
        )
        let alert = app.alerts["Off the trail"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "a walk that has left its trail should ask what the hiker means by it"
        )
        XCTAssertTrue(alert.buttons["Record Instead"].exists, "and offer to record instead")
        alert.buttons["Keep Following"].tap()
        XCTAssertTrue(waitUntil { !alert.exists }, "Keep Following should close the question")
        XCTAssertTrue(element("map-sheet", in: app).exists, "and the sheet should have survived it")

        openHikeDetail(in: app)
        let phase = element("walk-phase", in: app)
        XCTAssertTrue(
            phase.waitForExistence(timeout: UITestTimeout.navigation),
            "the hike should still be under way on its trail"
        )
        expectLabel(phase, contains: "Active")
        XCTAssertFalse(
            alert.waitForExistence(timeout: UITestTimeout.brief),
            "and the same departure should not be asked about again"
        )
    }

    /// *Record Instead* ends the walk and opens a recording that already
    /// holds what the walk covered: its points are counted before the first
    /// fix of its own could have arrived.
    ///
    /// The question is raised under the launch's location prompt, and is put
    /// up once the prompt is answered: the wait a question raised in a pocket
    /// has for the app to come to the front.
    @MainActor
    func testRecordingInsteadBeginsWithWhatTheWalkCovered() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
                "--ui-test-seed-walks=LeftTrail",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.offTrailCoordinate)
        defer { XCUIDevice.shared.location = nil }
        launch(app)
        XCTAssertTrue(element("map-sheet", in: app).waitForExistence(timeout: UITestTimeout.navigation))
        answerLaunchPrompt(in: app)

        let alert = app.alerts["Off the trail"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: UITestTimeout.navigation),
            "a walk that has left its trail should ask once the app is in front to be asked"
        )
        alert.buttons["Record Instead"].tap()

        XCTAssertTrue(
            app.navigationBars["Record Hike"].waitForExistence(timeout: UITestTimeout.navigation),
            "recording instead should open the recording"
        )
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(
            waitForPointCount(atLeast: Self.carriedPoints, in: points) { /* nothing to deliver: they were carried */ },
            "the recording should begin with what the walk covered, not with its own first fix"
        )
        XCTAssertFalse(alert.exists, "and the question should be answered")
    }

    /// More points than a recording could have taken of its own in the
    /// moment it has had, and far fewer than the fixture's walk hands over.
    private static let carriedPoints = 5

    /// Enough taps to land one inside another's presentation, and few enough
    /// that the test is over in a couple of seconds.
    private static let rapidTaps = 5
}
