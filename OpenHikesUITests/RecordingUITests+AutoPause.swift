//
//  RecordingUITests+AutoPause.swift
//  OpenHikesUITests
//
//  Auto-Pause on the recording screen (#1470): the one scenario that walks to
//  a place, stays there, and walks on.
//

import CoreLocation
import XCTest

extension RecordingUITests {
    /// Auto-Pause, from the stop to the saved hike (#1470): a recording that
    /// stays in one place pauses itself, walking on resumes it as the next
    /// segment, and the hike it is saved as shows both.
    ///
    /// The stop is `--ui-test-auto-pause-seconds` long instead of five
    /// minutes. Where it is, what ends it and what the recorder does about it
    /// are the shipping rule's, on positions alone: a simulator has no
    /// motion sensors to confirm with.
    @MainActor
    func testARecordingPausesItselfAtAStopAndResumesAsTheNextSegment() {
        let app = makeApp(
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-auto-pause-seconds=\(Self.stopSeconds)",
            ]
        )
        app.resetAuthorizationStatus(for: .location)
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.stopWalk(step: 0))
        defer { XCUIDevice.shared.location = nil }

        launch(app)
        startRecording(in: app)

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: UITestTimeout.existence))
        let walkIn = (0..<Self.walkInFixes).map { Self.stopWalk(step: $0) }
        walkRecordedTrace(walkIn, countedBy: points, pace: Self.stopWalkPace)
        let phase = element("recording-phase", in: app)
        expectLabel(phase, contains: "Recording")

        // Staying where the walk stopped. Core Location holds back a position
        // that has not moved its distance filter, in a simulator as on a
        // bench, so standing still is silence, and a simulator has no motion
        // sensor to say the silence is a stop. So the scenario does what a
        // hiker in a shop does: it paces between two spots a dozen metres
        // from where it stopped, each far enough from the other to be
        // delivered and both well inside the stop's area. Waited on by what
        // it causes.
        var pacing = 0
        let stopped = waitUntil(timeout: UITestTimeout.trace) {
            pacing += 1
            setSimulatedLocation(Self.besideTheStop(pacing))
            return phase.label.contains("Paused")
        }
        XCTAssertTrue(stopped, "a recording that stays in one place should pause itself; the phase read \(phase.label)")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto-paused")).firstMatch
                .waitForExistence(timeout: UITestTimeout.navigation),
            "the screen should say the app made the pause, and that it will end by itself"
        )

        // Walking on: the first fix clear of the stop resumes the recording,
        // and is the next segment's first point.
        Thread.sleep(forTimeInterval: Self.stopWalkPace)
        setSimulatedLocation(Self.stopWalk(step: Self.walkInFixes))
        expectLabel(phase, contains: "Recording")
        let segments = app.descendants(matching: .any).matching(identifier: "hike-segment")
        XCTAssertTrue(
            waitUntil { segments.count == 2 },
            "the walk on should be the second segment; found \(segments.count)"
        )
        XCTAssertEqual(segments.element(boundBy: 0).label, "Segment 1")
        let second = segments.element(boundBy: 1)
        XCTAssertEqual(second.label, "Segment 2")

        // A segment of one fix is a place, not a walk, so the walk goes on
        // until the second segment says it has grown. Waited on by what the
        // row says rather than by a count of points: the pause gave back the
        // fixes kept inside the stop, however many a slow machine let in.
        let atTheDoor = second.value as? String
        var hasGrown = false
        for step in (Self.walkInFixes + 1)...(Self.walkInFixes + Self.walkOutFixes) where !hasGrown {
            Thread.sleep(forTimeInterval: Self.stopWalkPace)
            setSimulatedLocation(Self.stopWalk(step: step))
            hasGrown = waitUntil(timeout: Self.stopWalkPace) { (second.value as? String) != atTheDoor }
        }
        XCTAssertTrue(hasGrown, "the second segment never grew past \(atTheDoor ?? "nothing")")

        stopRecording(named: Self.stoppedHikeName, in: app)
        XCTAssertTrue(
            app.navigationBars[Self.stoppedHikeName].waitForExistence(timeout: Self.stoppedSaveTimeout),
            "a recording with a stop in it should save as a hike"
        )
        XCTAssertTrue(
            waitUntil(timeout: UITestTimeout.existence) { segments.count == 2 },
            "the saved hike should show the two segments its stop cut it into; found \(segments.count)"
        )
    }

    /// How long this scenario's stop takes, in seconds: long enough to be
    /// more than the gap between two fixes of its walk, and short enough to
    /// wait out.
    private static let stopSeconds = 8
    /// A fix every six seconds and 40 m. Each is further from the last than
    /// the stop's area reaches, so however late a fix arrives on a loaded
    /// machine, the walk itself is never taken for a stop; and slower than
    /// the eight metres a second `RecordingFixPolicy` refuses.
    private static let stopWalkPace: TimeInterval = 6
    private static let stopWalkStepDegrees = 0.00036
    private static let walkInFixes = 3
    private static let walkOutFixes = 3
    /// A dozen metres, north and east of where the walk stopped: more than
    /// the ten the recording's distance filter holds back, and a third of
    /// the way to the edge of the stop's area.
    private static let pacingLatitudeDegrees = 0.000108
    private static let pacingLongitudeDegrees = 0.00016
    private static let stoppedHikeName = "Shop Run"
    /// Saving writes the route and its widget payload.
    private static let stoppedSaveTimeout: TimeInterval = 20

    /// The `step`th fix of the scenario's walk north from the trailhead.
    private static func stopWalk(step: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: UITestFixture.trailheadLatitude + Double(step) * stopWalkStepDegrees,
            longitude: UITestFixture.trailheadLongitude
        )
    }

    /// One of two spots beside where the walk in ended, taken in turn.
    private static func besideTheStop(_ turn: Int) -> CLLocationCoordinate2D {
        let stop = stopWalk(step: walkInFixes - 1)
        return turn.isMultiple(of: 2)
            ? CLLocationCoordinate2D(latitude: stop.latitude + pacingLatitudeDegrees, longitude: stop.longitude)
            : CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude + pacingLongitudeDegrees)
    }
}
