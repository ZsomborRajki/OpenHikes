//
//  PerformanceUITests+Walk.swift
//  OpenHikesUITests
//
//  What a walk along a followed trail costs per matched fix. In its own file
//  for the reason the photo scenarios are: `PerformanceUITests.swift` holds
//  the harness, and the class had reached its length.
//

import XCTest

extension PerformanceUITests {
    /// The walk's counterpart to `testLiveRecordingCostPerFix`. A matched fix
    /// extends the walk's coverage and moves the progress row; it must not
    /// re-run the hike detail's body, the sheet or the hikes list — the
    /// coverage lives in `TrailWalkSession`, whose per-fix properties only
    /// the progress row reads. The sidecar write behind it is counted at the
    /// feed's cadence, not at the fix rate.
    @MainActor
    func testLiveWalkCostPerFix() {
        let app = launch(
            scenario: "walk",
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-import-gpx=\(UITestFixture.gpxName)",
            ]
        )
        // No authorization reset, for the reason the recording scenario
        // gives: the permission is granted out-of-band by the script.
        addLocationPermissionMonitor()
        setSimulatedLocation(UITestFixture.trailPoints[0])
        defer { XCUIDevice.shared.location = nil }
        bringToForeground(app)
        awaitImportedHike(in: app)
        hikeRow(titled: UITestFixture.importedHikeTitle, in: app).tap()

        // The walk starts on the first matched fix, before the baseline is
        // read, so the measured window holds only the fixes that extend it.
        let phase = element("walk-phase", in: app)
        XCTAssertTrue(phase.waitForExistence(timeout: UITestTimeout.launch))
        let progress = element("trail-progress", in: app)
        XCTAssertTrue(progress.waitForExistence(timeout: UITestTimeout.launch))
        settle(in: app)

        let before = counters(in: app)
        let started = Date().timeIntervalSince1970
        for coordinate in UITestFixture.trailPoints.dropFirst() {
            Thread.sleep(forTimeInterval: UITestFixture.paceSeconds)
            setSimulatedLocation(coordinate)
        }
        settle(in: app)
        let after = counters(in: app)
        let elapsed = Date().timeIntervalSince1970 - started
        printPhase("walk", from: started, to: Date().timeIntervalSince1970)

        let delta = PerformanceCounterDelta(before: before, after: after)
        let fixes = delta.count(of: "LiveFollowUpdate")
        XCTAssertGreaterThan(fixes, 0, "no fix reached the follow loop, so nothing was measured")
        report(delta, phase: "walk", perEvent: "LiveFollowUpdate")

        // The bodies a matched fix must not reach. Zero rather than a ratio:
        // the walk's coarse properties change on a tap and nothing here taps.
        for body in ["HikeDetailBody", "MapSheetHikesBody", "MapSheetBody", "OpenHikesViewBody"] {
            assertNoMoreThan(0, of: body, in: delta, phase: "walk")
        }
        // The sidecar is written once per 45-second window at most, never
        // per fix; the "+ 1" is the window this phase started inside.
        XCTAssertLessThanOrEqual(
            delta.count(of: "TrailWalkPersisted"),
            (elapsed / Self.walkPersistIntervalSeconds).rounded(.up) + 1,
            "the walk was written to the sidecar \(delta.count(of: "TrailWalkPersisted")) times "
                + "over \(Int(elapsed)) seconds and \(fixes) fixes — coverage is being written per fix"
        )
        assertNoStall(in: delta, phase: "walk")
        finish(in: app)
    }

    /// `TrailWalkPolicy.persistInterval`, restated because this bundle runs
    /// out of process and cannot import the app.
    private static let walkPersistIntervalSeconds: Double = 45
}
