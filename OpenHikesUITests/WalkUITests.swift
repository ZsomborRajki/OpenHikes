//
//  WalkUITests.swift
//  OpenHikesUITests
//
//  Walking a followed trail: the walk that starts on the first matched fix,
//  its Pause / Resume / End controls, the summary an end produces, and the
//  History segment that lists it afterwards.
//
//  Kept out of CI alongside `RecordingUITests`, and for the same reason:
//  every test here drives real simulator Core Location at a pace, and a
//  shared runner makes that slow and flaky. `Scripts/run-ui-tests.sh` runs it
//  locally, and `AccessibilityLabelUITests` carries the one VoiceOver case
//  that needs no walk to be taken.
//

import CoreLocation
import XCTest

nonisolated final class WalkUITests: XCTestCase {
    /// A walk starts the way auto-follow starts, on the first matched fix,
    /// and can be paused and resumed without ending. The controls exist
    /// only once there is a walk to control: opening a trail is not walking
    /// it — so the launch starts a kilometre off the trail, where a fix
    /// matches nothing, and steps onto it afterwards.
    @MainActor
    func testWalkStartsOnAMatchedFixAndPauses() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
        ])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.offTrailCoordinate)
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        openHikeDetail(in: app)
        XCTAssertFalse(
            element("walk-controls", in: app).exists,
            "looking at a trail must not offer walk controls before a fix matched it"
        )

        setSimulatedLocation(UITestFixture.trailPoints[1])
        let phase = element("walk-phase", in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.trace))
        expectPhase(phase, contains: "Active")

        scrollToTap(app.buttons["Pause Walk"], in: app)
        expectPhase(phase, contains: "Paused")
        XCTAssertFalse(
            app.buttons["Pause"].exists,
            "the recording's own Pause must not appear on a hike screen"
        )

        app.buttons["Resume Walk"].tap()
        expectPhase(phase, contains: "Active")
    }

    /// Ending a walk produces a summary whose percentage is coverage, and the
    /// summary is reachable again from the trail's History segment afterwards.
    @MainActor
    func testEndingAWalkShowsItsSummaryAndListsIt() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
        ])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailPoints[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        openHikeDetail(in: app)
        let phase = element("walk-phase", in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.trace))
        // Four points span 116 m of trail, past the minimum a walk needs to
        // be kept. Paced, not waited on: a follow has no speed gate, and the
        // effect waited for is the progress row moving.
        let progress = element("trail-progress", in: app)
        XCTAssertTrue(progress.waitForExistence(timeout: UITestTimeout.existence))
        for point in UITestFixture.trailPoints[1...3] {
            let before = progress.value as? String
            Thread.sleep(forTimeInterval: UITestFixture.paceSeconds)
            setSimulatedLocation(point)
            XCTAssertTrue(
                waitUntilValueChanges(from: before, on: progress),
                "the fix at \(point.latitude) never moved the progress row"
            )
        }

        scrollToTap(app.buttons["End Walk"], in: app)
        confirmEndWalk(in: app)
        XCTAssertTrue(
            app.navigationBars["Walk Summary"].waitForExistence(timeout: UITestTimeout.navigation)
        )
        let completion = element("walk-completion", in: app)
        XCTAssertTrue(completion.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(
            (completion.value as? String ?? "").contains("percent"),
            "the summary leads with how much of the trail was covered"
        )

        popScreen(in: app)
        app.segmentedControls["walk-segment"].buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(identifier: "walk-row")
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        row.tap()
        XCTAssertTrue(
            app.navigationBars["Walk Summary"].waitForExistence(timeout: UITestTimeout.navigation)
        )
    }

    /// A seeded walk, so the history and the summary can be checked in
    /// seconds rather than after a simulated stroll. Mirrors
    /// `--ui-test-seed-photos=`.
    @MainActor
    func testHistorySegmentListsASeededWalkWithItsPercentage() {
        let app = launchApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            "--ui-test-seed-walks=HalfLoop",
        ])
        openHikeDetail(in: app)
        app.segmentedControls["walk-segment"].buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(identifier: "walk-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: UITestTimeout.existence))
        XCTAssertTrue(
            (row.value as? String ?? "").contains("50"),
            "the row reads as one element: date, then percentage and how it ended"
        )
    }

    /// Starting a recording while a walk is under way changes nothing on the
    /// recording screen: same phase label, same controls, no walk controls.
    /// The walk's own badge is still there when the trail is reopened.
    @MainActor
    func testARecordingIsUnchangedByAWalkInProgress() {
        let app = makeApp(arguments: [
            "--ui-test-expanded-sheet",
            "--ui-test-enable-location",
            "--ui-test-import-gpx=\(UITestFixture.gpxName)",
        ])
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailPoints[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        openHikeDetail(in: app)
        setSimulatedLocation(UITestFixture.trailPoints[1])
        XCTAssertTrue(element("walk-phase", in: app).waitForExistence(timeout: UITestTimeout.trace))

        popScreen(in: app)
        startRecording(in: app)
        let recordingPhase = element("recording-phase", in: app)
        XCTAssertTrue(recordingPhase.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertTrue(app.buttons["Stop"].exists)
        XCTAssertFalse(element("walk-controls", in: app).exists)
        XCTAssertFalse(app.buttons["End Walk"].exists)

        popScreen(in: app)
        let walked = awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        XCTAssertTrue(
            walked.label.contains("Active"),
            "starting a recording neither pauses nor ends the walk on the trail beside it"
        )
    }

    // MARK: - Helpers

    @MainActor
    private func expectPhase(_ phase: XCUIElement, contains text: String) {
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", text),
            evaluatedWith: phase
        )
        waitForExpectations(timeout: UITestTimeout.navigation)
    }

    /// Confirms the "End this walk?" dialog, found the way `confirmDiscard`
    /// finds its own: the confirming button shares its title with the one
    /// that raised it, so it has to be found inside the presentation.
    @MainActor
    private func confirmEndWalk(in app: XCUIApplication) {
        let title = "End Walk"
        for container in [app.sheets, app.alerts] {
            let presented = container.firstMatch
            guard presented.waitForExistence(timeout: UITestTimeout.navigation)
            else { continue }
            let confirm = presented.buttons[title]
            guard confirm.waitForExistence(timeout: UITestTimeout.navigation)
            else { continue }
            confirm.tap()
            return
        }
        XCTFail("ending a walk should ask before closing its record")
    }

    /// Polls an element's value until it differs from `previous`, so a fix
    /// is waited on by the row it moves rather than by a duration.
    @MainActor
    private func waitUntilValueChanges(
        from previous: String?,
        on element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, (element.value as? String) != previous { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
