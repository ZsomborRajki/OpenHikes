//
//  RecordingUITests+Stop.swift
//  OpenHikesUITests
//
//  What a tap on Stop asks: a name, in a field that opens holding the offered
//  one with all of it selected, beside the two other ways out — and nothing
//  at all of a recording with no line to save.
//
//  The selection is asserted by what typing does to it. Every other test in
//  this bundle names its hike through `stopRecording(named:in:)`, which
//  selects the field's text itself before typing and so would pass whether
//  the alert had selected it or not. Here the name is typed straight into
//  the field as it opened, where only a selection is replaced.
//

import CoreLocation
import XCTest

extension RecordingUITests {
    /// Saving writes the route plus its widget payload.
    private static let savedHikeTimeout: TimeInterval = 20
    /// How many of the fixture trail's points make a line worth saving.
    private static let lineLength = 3

    /// Launches, starts a recording and walks it far enough to have a line.
    @MainActor
    private func recordALine() -> XCUIApplication {
        let app = startARecording()
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        walkRecordedTrace(Array(UITestFixture.trailPoints.prefix(Self.lineLength)), countedBy: points)
        return app
    }

    /// Launches and starts a recording at the trailhead.
    ///
    /// The caller clears the simulated location: a `defer` here would clear
    /// it before the walk it is for.
    @MainActor
    private func startARecording() -> XCUIApplication {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailheadCoordinate)
        launch(app)
        startRecording(in: app)
        return app
    }

    /// Taps Stop and waits for the alert it raises and the field in it.
    @MainActor
    private func askToStop(in app: XCUIApplication) -> (prompt: XCUIElement, field: XCUIElement) {
        tapWhenReady(app.buttons["Stop"])
        let prompt = app.alerts["Name Your Hike"]
        XCTAssertTrue(prompt.waitForExistence(timeout: UITestTimeout.navigation))
        let field = prompt.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UITestTimeout.navigation))
        return (prompt, field)
    }

    /// The offered name is the field's text rather than its placeholder, and
    /// it is selected: the first key replaces it.
    @MainActor
    func testTheStopQuestionOpensWithItsNameSelected() {
        defer { XCUIDevice.shared.location = nil }
        let app = recordALine()

        let (prompt, field) = askToStop(in: app)
        let offered = field.value as? String ?? ""
        XCTAssertTrue(
            offered.contains("Hike"),
            "the field should open holding the offered name, held \"\(offered)\""
        )

        // No tap and no selection gesture first: typed into the field as it
        // opened, so text the alert had not selected would be added to.
        field.typeText("Summit Day")
        XCTAssertEqual(
            field.value as? String,
            "Summit Day",
            "typing should replace the offered name, which opens selected"
        )
        prompt.buttons["Save"].tap()

        XCTAssertTrue(
            app.navigationBars["Summit Day"].waitForExistence(timeout: Self.savedHikeTimeout),
            "the hike should be saved under the name typed over the offered one"
        )
    }

    /// Stop, then Save, with nothing typed: the hike is called what the
    /// field said.
    @MainActor
    func testSavingTheOfferedNameKeepsIt() {
        defer { XCUIDevice.shared.location = nil }
        let app = recordALine()

        let (prompt, field) = askToStop(in: app)
        let offered = field.value as? String ?? ""
        XCTAssertFalse(offered.isEmpty, "the field should open holding the offered name")
        prompt.buttons["Save"].tap()

        XCTAssertTrue(
            app.navigationBars[offered].waitForExistence(timeout: Self.savedHikeTimeout),
            "the hike should be saved under the name the alert offered, \"\(offered)\""
        )
    }

    /// The alert's two other answers. Keep Recording changes nothing, and
    /// Discard Recording asks once more before the walk goes, with no pause
    /// needed to reach it.
    @MainActor
    func testTheStopQuestionCanKeepRecordingOrDiscard() {
        defer { XCUIDevice.shared.location = nil }
        let app = recordALine()
        let phase = element("recording-phase", in: app)

        var prompt = askToStop(in: app).prompt
        prompt.buttons["Keep Recording"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: UITestTimeout.navigation))
        expectLabel(phase, contains: "Recording")

        prompt = askToStop(in: app).prompt
        prompt.buttons["Discard Recording"].tap()
        // The question follows the name alert as an alert of its own, and its
        // confirming button has the title of the one just tapped: found in
        // the question, not by title alone.
        let question = app.alerts["Discard this recording?"]
        XCTAssertTrue(
            question.waitForExistence(timeout: UITestTimeout.navigation),
            "discarding from the stop question should ask before throwing a walk away"
        )
        question.buttons["Discard Recording"].tap()

        XCTAssertTrue(
            app.staticTexts["No hikes yet"].waitForExistence(timeout: UITestTimeout.existence),
            "a recording discarded from the stop question should leave the list as it found it"
        )
    }

    /// A recording started by mistake. The fix set before launch is refused
    /// as older than the recording, so it has no point at all, and Stop ends
    /// it: were anything asked, nothing here would answer and the list would
    /// never come back.
    @MainActor
    func testStoppingARecordingWithNoLineEndsItWithoutAsking() {
        defer { XCUIDevice.shared.location = nil }
        let app = startARecording()

        tapWhenReady(app.buttons["Stop"])

        XCTAssertTrue(
            app.staticTexts["No hikes yet"].waitForExistence(timeout: UITestTimeout.existence),
            "Stop should end a recording with nothing in it and leave no hike behind"
        )
    }
}
