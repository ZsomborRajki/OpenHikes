//
//  RecordingUITests.swift
//  OpenHikesUITests
//
//  A walk, from the first fix to the hike it becomes: starting, pausing,
//  discarding, retrying a refused save, and deciding afterwards, in *Edit
//  Route*, which line the hike keeps.
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
        expectPhase(phase, contains: "Recording")
    }

    /// Pausing stops the recording without ending it, and resuming picks it
    /// back up — a distinction the phase label is the only report of.
    ///
    /// No discard button in either phase is part of the same assertion: a
    /// recording is thrown away only as an answer to Stop's question, which is
    /// what stops a walk being lost to a mis-tap mid-stride.
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

        // A fix taken after Start: the one set before launch is refused as
        // older than the recording, and resuming a recording that never had a
        // point goes back to finding GPS rather than to "Recording".
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        walkRecordedTrace([UITestFixture.trailheadCoordinate], countedBy: points)
        let phase = element("recording-phase", in: app)
        XCTAssertTrue(
            phase.waitForExistence(timeout: UITestTimeout.navigation)
        )
        expectPhase(phase, contains: "Recording")
        let discard = app.buttons["Discard Recording"]
        XCTAssertFalse(
            discard.exists,
            "a running recording must not offer a one-tap way to lose it"
        )

        tapWhenReady(app.buttons["Pause"])
        expectPhase(phase, contains: "Paused")
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: UITestTimeout.navigation))
        XCTAssertFalse(discard.exists, "nor a paused one: Stop's question is where a recording is thrown away")

        tapWhenReady(app.buttons["Resume"])
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
        pauseALine(in: app)
        discardByStopping(in: app)

        XCTAssertTrue(
            app.staticTexts["No hikes yet"]
                .waitForExistence(timeout: UITestTimeout.existence),
            "a discarded recording should leave the list as it found it"
        )
    }

    /// The sheet's chrome sits where it did before a walk was started.
    ///
    /// The recording screen has a navigation bar and the sheet's own root has
    /// none, so popping one takes the bar with it. When the bar stays behind
    /// it is empty, 54 points tall, and directly above the search field — a
    /// gap that looks like padding nobody wrote, and that goes away again the
    /// moment any other screen is pushed and popped.
    ///
    /// Measured as the search field's offset from the top of the sheet rather
    /// than its position on screen, because the detent is not the subject: a
    /// sheet resting somewhere else moves the field without anything being
    /// wrong. The bar count is the same claim stated the other way round, and
    /// is what says *why* when the offset is out.
    @MainActor
    func testDiscardingARecordingLeavesTheSheetChromeWhereItWas() {
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

        let search = element("map-search", in: app)
        let sheet = element("map-sheet", in: app)
        XCTAssertTrue(
            search.waitForExistence(timeout: UITestTimeout.navigation)
        )
        let restingOffset = search.frame.minY - sheet.frame.minY

        startRecording(in: app)
        pauseALine(in: app)
        discardByStopping(in: app)

        XCTAssertTrue(
            app.staticTexts["No hikes yet"]
                .waitForExistence(timeout: UITestTimeout.existence)
        )
        XCTAssertTrue(
            search.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertEqual(
            search.frame.minY - sheet.frame.minY,
            restingOffset,
            accuracy: 2,
            "a discarded recording should leave the search field where it found it"
        )
        XCTAssertEqual(
            app.navigationBars.count,
            0,
            "the sheet's own screen has no navigation bar to come back to"
        )
    }

    /// The full recording round trip: walk a trace the matcher snaps onto a
    /// bundled trail, stop, and land on the saved hike — then decide in *Edit
    /// Route*, from the notice the hike carries, which line it keeps.
    ///
    /// The recording used to stop in a review before it was a hike at all.
    @MainActor
    func testASnappedRecordingIsSavedThenCheckedInEditRoute() {
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
        stopRecording(named: Self.checkedHikeName, in: app)

        XCTAssertTrue(
            app.navigationBars[Self.checkedHikeName].waitForExistence(timeout: Self.saveTimeout),
            "a snapped recording should be saved at once, under the name it was given"
        )
        openRouteChecks(in: app, saying: "1 section to check")

        let keepTrail = element("review-choice-trail", in: app)
        let useGPS = element("review-choice-gps", in: app)
        XCTAssertTrue(
            keepTrail.waitForExistence(timeout: Self.matchTimeout),
            "the section the matcher moved should be offered"
        )
        XCTAssertTrue(
            useGPS.waitForExistence(timeout: UITestTimeout.navigation)
        )
        XCTAssertTrue(
            keepTrail.isSelected,
            "the matched trail is the line the hike was saved with"
        )
        let save = element("route-trim-save", in: app)
        XCTAssertFalse(save.isEnabled, "nothing is changed yet")

        scrollToTap(useGPS, in: app)
        XCTAssertTrue(
            waitUntilSelected(useGPS),
            "tapping a choice should move the checkmark to it"
        )
        XCTAssertFalse(keepTrail.isSelected)
        XCTAssertTrue(waitUntil { save.isEnabled }, "an answer changed is something to save")
        save.tap()

        XCTAssertTrue(
            app.navigationBars[Self.checkedHikeName].waitForExistence(timeout: Self.saveTimeout),
            "a save goes back to the hike"
        )
        expectTheAnswerWasKept(in: app)
    }

    /// Back on the hike after a saved answer: the notice is gone, and *Edit
    /// Route* opens on the answer with the saved line kept to go back to.
    @MainActor
    private func expectTheAnswerWasKept(in app: XCUIApplication) {
        XCTAssertTrue(
            element("hike-route-check", in: app).waitForNonExistence(timeout: UITestTimeout.navigation),
            "a hike that has been answered for stops asking"
        )
        openEditRoute(in: app)
        XCTAssertTrue(
            waitUntilSelected(element("review-choice-gps", in: app)),
            "the answer is kept with the hike"
        )
        XCTAssertTrue(
            element("route-trim-revert", in: app).waitForExistence(timeout: UITestTimeout.navigation),
            "and the line it was saved with is kept to go back to"
        )
    }

    /// A walk that crosses two trails is saved with a section for each, and
    /// *Looks Good* answers for both without changing the line.
    @MainActor
    func testATwoTrailWalkKeepsBothSectionsUntilItLooksGood() {
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
        stopRecording(named: Self.checkedHikeName, in: app)

        XCTAssertTrue(
            app.navigationBars[Self.checkedHikeName].waitForExistence(timeout: Self.saveTimeout),
            "a walk over two trails should be saved at once"
        )
        openRouteChecks(in: app, saying: "2 sections to check")

        let trails = app.buttons.matching(identifier: "review-choice-trail")
        XCTAssertTrue(
            trails.firstMatch.waitForExistence(timeout: Self.matchTimeout),
            "the sections should be offered"
        )
        XCTAssertEqual(trails.count, 2, "a second section is what this walk was recorded to produce")
        XCTAssertFalse(element("route-trim-revert", in: app).exists, "a question kept is not an edit")

        scrollToTap(element("route-checks-confirm", in: app), in: app, attempts: 12)

        XCTAssertTrue(
            app.navigationBars[Self.checkedHikeName].waitForExistence(timeout: Self.saveTimeout),
            "Looks Good goes back to the hike"
        )
        XCTAssertTrue(
            element("hike-route-check", in: app).waitForNonExistence(timeout: UITestTimeout.navigation),
            "and the hike stops asking"
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
        stopRecording(named: Self.checkedHikeName, in: app)

        let retry = element("recording-retry-save", in: app)
        XCTAssertTrue(
            retry.waitForExistence(timeout: Self.saveTimeout),
            "a refused save should offer the walk back, not drop it"
        )
        retry.tap()

        XCTAssertTrue(
            app.navigationBars[Self.checkedHikeName]
                .waitForExistence(timeout: Self.saveTimeout),
            "the retry should save the hike the first attempt could not"
        )
    }

    /// Matching a trace against the bundled graph is real work on a cold
    /// simulator, and saving writes the route plus its widget payload.
    /// Reading the saved line and its trace back, and measuring them, is
    /// real work on a cold simulator.
    private static let matchTimeout: TimeInterval = 30
    private static let saveTimeout: TimeInterval = 20
    private static let checkedHikeName = "Checked Route"

    /// `file` and `line` are forwarded, or every phase that never arrived is
    /// reported against this line rather than the step that was waiting.
    @MainActor
    private func expectPhase(
        _ phase: XCUIElement,
        contains text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        expectLabel(phase, contains: text, file: file, line: line)
    }
}

// The two discard tests' steps, apart from the class's body for its length.
extension RecordingUITests {
    /// How many of the fixture trail's points make a line worth asking about.
    private static let discardedLineLength = 3

    /// Walks a short line and pauses it: a recording Stop asks about before
    /// it goes, rather than one it ends without a word.
    @MainActor
    func pauseALine(in app: XCUIApplication) {
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        walkRecordedTrace(Array(UITestFixture.trailPoints.prefix(Self.discardedLineLength)), countedBy: points)
        tapWhenReady(app.buttons["Pause"])
        expectLabel(element("recording-phase", in: app), contains: "Paused")
    }

    /// Throws the recording away the one way there is: Stop, the name
    /// alert's *Discard Recording*, and the question that follows it, whose
    /// confirming button has the title of the one just tapped — so it is
    /// found in the question, not by title alone.
    @MainActor
    func discardByStopping(in app: XCUIApplication) {
        tapWhenReady(app.buttons["Stop"])
        let prompt = app.alerts["Name Your Hike"]
        XCTAssertTrue(prompt.waitForExistence(timeout: UITestTimeout.navigation))
        prompt.buttons["Discard Recording"].tap()
        let question = app.alerts["Discard this recording?"]
        XCTAssertTrue(
            question.waitForExistence(timeout: UITestTimeout.navigation),
            "discarding should ask before throwing a walk away"
        )
        question.buttons["Discard Recording"].tap()
    }
}
