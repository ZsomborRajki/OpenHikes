//
//  WalkUITests.swift
//  OpenHikesUITests
//
//  Walking a followed trail: the offer the first matched fix makes, the walk
//  its Start begins, its Pause / Resume / End controls, the summary an end
//  produces, and the History segment that lists it afterwards.
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
    /// The first matched fix offers a walk rather than starting one; Start
    /// begins it, and it can be paused and resumed without ending. Nothing
    /// is offered before a fix has matched: opening a trail is not walking
    /// it — so the launch starts a kilometre off the trail, where a fix
    /// matches nothing, and steps onto it afterwards.
    @MainActor
    func testWalkIsOfferedOnAMatchedFixAndStartsOnStart() {
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
            element("walk-offer", in: app).exists,
            "looking at a trail must not offer a walk before a fix matched it"
        )

        setSimulatedLocation(UITestFixture.trailPoints[1])
        XCTAssertTrue(element("walk-offer", in: app).waitForExistence(timeout: UITestTimeout.trace))
        let phase = element("walk-phase", in: app)
        XCTAssertFalse(phase.exists, "a match offers the walk and starts nothing")

        acceptWalkOffer(in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.navigation))
        expectPhase(phase, contains: "Active")

        scrollToTap(app.buttons["Pause Hike"], in: app)
        expectPhase(phase, contains: "Paused")
        XCTAssertFalse(
            app.buttons["Pause"].exists,
            "the recording's own Pause must not appear on a hike screen"
        )

        app.buttons["Resume Hike"].tap()
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
        acceptWalkOffer(in: app)
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

        scrollToTap(app.buttons["End Hike"], in: app)
        confirmEndWalk(in: app)
        XCTAssertTrue(
            app.navigationBars["Hike Summary"].waitForExistence(timeout: UITestTimeout.navigation)
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
            app.navigationBars["Hike Summary"].waitForExistence(timeout: UITestTimeout.navigation)
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
            row.label.contains("50"),
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
        acceptWalkOffer(in: app)
        XCTAssertTrue(element("walk-phase", in: app).waitForExistence(timeout: UITestTimeout.trace))

        popScreen(in: app)
        startRecording(in: app)
        let recordingPhase = element("recording-phase", in: app)
        XCTAssertTrue(recordingPhase.waitForExistence(timeout: UITestTimeout.navigation))
        // The phase label arriving does not mean the controls beside it have
        // been drawn, so the two that must be there are waited for. The two
        // that must not are read straight after — by then the screen has
        // finished, which is what makes an absence worth asserting rather
        // than merely early.
        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(
            app.buttons["Stop"].waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertFalse(element("walk-controls", in: app).exists)
        XCTAssertFalse(app.buttons["End Hike"].exists)

        popScreen(in: app)
        let walked = awaitHikeRow(titled: UITestFixture.importedHikeTitle, in: app)
        // ``awaitHikeRow`` matches on the title the label *begins* with, and
        // the walk badge is appended to it. So the row can exist a redraw
        // before it says anything about the walk, and reading `.label` here
        // asked whether the walk was still active before the row had said.
        expectLabel(
            walked,
            contains: "Active",
            "starting a recording neither pauses nor ends the walk on the trail beside it",
            timeout: UITestTimeout.existence
        )
    }

    /// The switch owns the chart and the offer; the walk controls own phase.
    /// Advancing coverage while the chart stays parked catches a foreground
    /// feed that still returns early when following is off.
    @MainActor
    func testFollowingOffKeepsTheWalkActiveAndTheChartParked() {
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
        acceptWalkOffer(in: app)
        let phase = element("walk-phase", in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.trace))

        let follow = app.switches["Follow This Trail"]
        scrollToTap(follow, in: app)
        XCTAssertEqual(follow.value as? String, "0")
        expectPhase(phase, contains: "Active")
        let progress = element("trail-progress", in: app)
        XCTAssertTrue(scrollUntilVisible(progress, in: app))
        let chart = element("elevation-chart", in: app)
        let parked = chart.value as? String
        XCTAssertNotNil(parked)
        let before = progress.value as? String
        let remainingBefore = before?.components(separatedBy: ", ").last
        // One move spans 116 m, within the walk's gap bound. It proves the
        // foreground still accrues without depending on rapid static fixes,
        // which Core Location does not redeliver after the publish throttle.
        setSimulatedLocation(UITestFixture.trailPoints[3])
        XCTAssertTrue(waitUntilValueChanges(from: before, on: progress))
        let advanced = progress.value as? String
        XCTAssertNotEqual(
            advanced?.components(separatedBy: ", ").last,
            remainingBefore,
            "remaining distance must advance with coverage while the chart is parked"
        )
        XCTAssertEqual(chart.value as? String, parked, "coverage moves, the manual tracker stays put")
        expectPhase(phase, contains: "Active")

        popScreen(in: app)
        openHikeDetail(in: app)
        XCTAssertTrue(scrollUntilVisible(progress, in: app))
        XCTAssertEqual(
            progress.value as? String,
            advanced,
            "reopening must preserve both coverage and remaining distance"
        )

        XCTAssertTrue(scrollUntilVisible(app.buttons["Pause Hike"], in: app))
        app.buttons["Pause Hike"].tap()
        expectPhase(phase, contains: "Paused")
        scrollToTap(follow, in: app)
        expectPhase(phase, contains: "Paused")
        scrollToTap(follow, in: app)
        XCTAssertTrue(scrollUntilVisible(app.buttons["Resume Hike"], in: app))
        app.buttons["Resume Hike"].tap()
        expectPhase(phase, contains: "Active")
        XCTAssertEqual(follow.value as? String, "0", "Resume must preserve the display preference")
    }

    /// End under the keep threshold leaves the detail on screen. Enabling
    /// following must rearm the offer there, through the real binding and
    /// onChange.
    @MainActor
    func testFollowingOnRearmsAfterEndingAWalk() {
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
        acceptWalkOffer(in: app)
        let phase = element("walk-phase", in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.trace))
        scrollToTap(app.buttons["End Hike"], in: app)
        confirmEndWalk(in: app)
        XCTAssertTrue(phase.waitForNonExistence(timeout: UITestTimeout.navigation))

        let follow = app.switches["Follow This Trail"]
        scrollToTap(follow, in: app)
        XCTAssertEqual(follow.value as? String, "0")
        scrollToTap(follow, in: app)
        XCTAssertEqual(follow.value as? String, "1")
        acceptWalkOffer(in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.trace))
        expectPhase(phase, contains: "Active")
    }

    // MARK: - Helpers

    /// Confirms the "End this hike?" dialog, found the way `confirmDiscard`
    /// finds its own: the confirming button shares its title with the one
    /// that raised it, so it has to be found inside the presentation.
    @MainActor
    private func confirmEndWalk(in app: XCUIApplication) {
        let title = "End Hike"
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
        XCTFail("ending a hike should ask before closing its record")
    }
}

/// The two steps both halves of the walk suite take, outside the class body so
/// ``WalkUITests+Offer`` can reach them — a test case's own non-test members
/// have to be private.
extension WalkUITests {
    /// Waits for the walk the first matched fix offers, and starts it.
    @MainActor
    func acceptWalkOffer(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let start = element("walk-offer-start", in: app)
        XCTAssertTrue(
            start.waitForExistence(timeout: UITestTimeout.trace),
            "a matched fix should offer the walk",
            file: file,
            line: line
        )
        scrollToTap(start, in: app)
    }

    /// `file` and `line` are forwarded, or every phase that never arrived is
    /// reported against this line rather than the step that was waiting.
    @MainActor
    func expectPhase(
        _ phase: XCUIElement,
        contains text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        expectLabel(phase, contains: text, file: file, line: line)
    }
}
