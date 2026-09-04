//
//  RecordingUITests.swift
//  OpenHikesUITests
//
//  A walk, from the first fix to the hike it becomes: starting, pausing,
//  discarding, retrying a refused save, and deciding in review which line the
//  hike keeps.
//
//  Split from ``OpenHikesUITests`` because every test here spoofs Core
//  Location and walks a trace in real time — they are the slow, timing-shaped
//  half of the bundle, and keeping them together makes them runnable on their
//  own through `Scripts/run-ui-tests.sh --suite RecordingUITests --all`.
//

import CoreLocation
import XCTest

nonisolated final class RecordingUITests: XCTestCase {
    @MainActor
    func testSimulatedLocationStartsRecording() {
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

        setSimulatedLocation(
            CLLocationCoordinate2D(latitude: 47.718598, longitude: 12.831420)
        )
        let phase = element("recording-phase", in: app)
        XCTAssertTrue(
            phase.waitForExistence(timeout: UITestTimeout.navigation)
        )
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Recording"),
            evaluatedWith: phase
        )
        waitForExpectations(timeout: UITestTimeout.navigation)
    }

    /// Pausing stops the recording without ending it, and resuming picks it
    /// back up — a distinction the phase label is the only report of.
    ///
    /// The discard button is part of the same assertion: it exists while
    /// paused and not while recording, which is what stops a walk being thrown
    /// away by a mis-tap mid-stride.
    @MainActor
    func testPausingAndResumingARecording() {
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
        let discard = app.buttons["Discard Recording"]
        XCTAssertFalse(
            discard.exists,
            "a running recording must not offer a one-tap way to lose it"
        )

        app.buttons["Pause"].tap()
        expectPhase(phase, contains: "Paused")
        XCTAssertTrue(
            discard.waitForExistence(timeout: UITestTimeout.navigation),
            "a paused recording is where discarding is offered"
        )

        app.buttons["Resume"].tap()
        expectPhase(phase, contains: "Recording")
    }

    /// Discarding leaves nothing behind — not a hike, and not the draft row
    /// the recorder inserts the moment a recording starts.
    ///
    /// That draft is a real persisted `Hike` with `isRecording` set, which is
    /// what makes this worth asserting: "no hike was saved" and "the list is
    /// empty" are two different claims, and only the second catches a discard
    /// that forgot the draft.
    @MainActor
    func testDiscardingARecordingSavesNothing() {
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
        app.buttons["Pause"].tap()
        expectPhase(phase, contains: "Paused")

        app.buttons["Discard Recording"].tap()
        confirmDiscard(in: app)

        XCTAssertTrue(
            app.staticTexts["No hikes yet"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "a discarded recording should leave the list as it found it"
        )
    }

    /// The full recording round trip: walk a trace the matcher can snap onto a
    /// bundled trail, then decide in review which line the hike keeps.
    @MainActor
    func testReviewsSnappedRouteAfterStopping() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph=\(UITestFixture.trailGraphName)",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.reviewableTrace[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        walkRecordedTrace(UITestFixture.reviewableTrace, countedBy: points)
        stopRecording(named: Self.reviewedHikeName, in: app)

        XCTAssertTrue(
            element("review-section-title", in: app)
                .waitForExistence(timeout: Self.reviewTimeout),
            "a snapped recording should stop in review"
        )
        let keepTrail = element("review-choice-trail", in: app)
        let useGPS = element("review-choice-gps", in: app)
        XCTAssertTrue(keepTrail.exists)
        XCTAssertTrue(useGPS.exists)
        XCTAssertTrue(
            keepTrail.isSelected,
            "the matched trail is the standing choice"
        )

        scrollToTap(useGPS, in: app)
        XCTAssertTrue(
            waitUntilSelected(useGPS),
            "tapping a choice should move the checkmark to it"
        )
        XCTAssertFalse(keepTrail.isSelected)

        scrollToTap(element("review-save-hike", in: app), in: app)

        XCTAssertTrue(
            app.navigationBars[Self.reviewedHikeName]
                .waitForExistence(timeout: Self.saveTimeout),
            "the reviewed hike should be saved under the name it was given"
        )
    }

    /// Reviewing a walk that crosses two trails, which is the only shape in
    /// which Previous and Next mean anything.
    ///
    /// The two are asserted as a pair: Previous is disabled on the first
    /// section — there is nowhere back to go — and the titles either side of a
    /// Next are different, which is what proves the button moved the review
    /// rather than merely redrawing it.
    @MainActor
    func testWalkingBetweenReviewSections() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph="
                    + UITestMultiSectionFixture.trailGraphName,
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestMultiSectionFixture.trace[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        walkRecordedTrace(UITestMultiSectionFixture.trace, countedBy: points)
        stopRecording(named: Self.reviewedHikeName, in: app)

        let title = element("review-section-title", in: app)
        XCTAssertTrue(
            title.waitForExistence(timeout: Self.reviewTimeout),
            "a walk over two trails should stop in review"
        )
        let previous = element("review-previous-section", in: app)
        let next = element("review-next-section", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertFalse(
            previous.isEnabled,
            "the first section has nothing before it"
        )
        XCTAssertTrue(
            next.isEnabled,
            "a second section is what this walk was recorded to produce"
        )

        let first = title.label
        scrollToTap(next, in: app)
        XCTAssertTrue(
            waitUntilLabelChanges(from: first, on: title),
            "Next should move the review on to the second section"
        )
        XCTAssertTrue(
            previous.isEnabled,
            "and should leave a way back to the first"
        )
    }

    /// The retry branch of the recording screen, which no sequence of taps can
    /// reach on its own: it needs the store to refuse a write.
    ///
    /// `--ui-test-fail-first-save` refuses exactly one — the save that ends a
    /// recording — so everything after the refusal is the shipping state
    /// machine, and the retry has something to succeed at.
    @MainActor
    func testRetryingASaveThatFailedOnce() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-fail-first-save",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.reviewableTrace[0])
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(
            points.waitForExistence(timeout: UITestTimeout.existence)
        )
        walkRecordedTrace(UITestFixture.reviewableTrace, countedBy: points)
        stopRecording(named: Self.reviewedHikeName, in: app)

        let retry = element("recording-retry-save", in: app)
        XCTAssertTrue(
            retry.waitForExistence(timeout: Self.saveTimeout),
            "a refused save should offer the walk back, not drop it"
        )
        retry.tap()

        XCTAssertTrue(
            app.navigationBars[Self.reviewedHikeName]
                .waitForExistence(timeout: Self.saveTimeout),
            "the retry should save the hike the first attempt could not"
        )
    }

    /// Matching a trace against the bundled graph is real work on a cold
    /// simulator, and saving writes the route plus its widget payload.
    private static let reviewTimeout: TimeInterval = 30
    private static let saveTimeout: TimeInterval = 20
    private static let reviewedHikeName = "Reviewed Route"

    @MainActor
    private func expectPhase(_ phase: XCUIElement, contains text: String) {
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", text),
            evaluatedWith: phase
        )
        waitForExpectations(timeout: UITestTimeout.navigation)
    }

    /// Which section the review is showing is drawn as a title and nothing
    /// else, so a Next that redrew without moving is indistinguishable from
    /// one that worked — unless the title is watched for a change.
    @MainActor
    private func waitUntilLabelChanges(
        from label: String,
        on element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label != label { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
