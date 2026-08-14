//
//  PerformanceUITests.swift
//  OpenHikesUITests
//
//  What this bundle can measure that no unit test can: the app as a user
//  drives it — a real SwiftUI render loop, a real MapKit view, real Core
//  Location fixes — and then ask how much work that actually cost.
//
//  Three sources are combined, deliberately, because each one is blind to
//  something the others see:
//
//  1. `PerformanceCounterProbe`, read through the accessibility tree. This is
//     the app's own `RenderSignpost` tally, live. It answers "how many times
//     did this body run *during this gesture*", which is the only question
//     that can distinguish a re-render caused by the interaction from one
//     caused by something the interaction was supposed to be insulated from.
//     Sampled before and after a phase and diffed, so a slow simulator moves
//     the wall clock but not the verdict.
//
//  2. XCTest's own metrics — `XCTApplicationLaunchMetric`, `XCTCPUMetric`,
//     `XCTMemoryMetric`, `XCTHitchMetric` — targeted at the app under test.
//     These see what the app cannot see about itself: launch time before its
//     first line runs, and hitches at the frame level.
//
//  3. `PerformanceLog`'s tab-separated file in the app container, pulled by
//     `Scripts/run-performance-tests.sh` afterwards. Nothing is asserted from
//     it; it is the timeline behind the numbers, which is what makes a
//     failure diagnosable instead of merely red.
//
//  The phase boundaries printed below are what ties (3) to this file: the
//  script reads them out of the `xcodebuild` log and attributes each event in
//  the app's timeline to the phase that was running at the time.
//
//  Thresholds are regression tripwires, not budgets. Each is set well above
//  what the app does today, because a performance test that fails when the CI
//  machine is busy gets disabled, and a disabled test measures nothing. The
//  precise figures belong in the generated report; the assertions exist to
//  catch a change in *shape* — a body that starts following GPS, a per-fix
//  cost that starts growing with route length.
//

import CoreLocation
import XCTest

nonisolated final class PerformanceUITests: XCTestCase {
    private static let importedHikeTitle = "Thumsee Loop (fast, simulated)"
    private static let gpxFixture = "ThumseeLoopFast"
    private static let trailGraphFixture = "ThumseeRidgePath"
    private static let probeIdentifier = "performance-counters"
    private static let existenceTimeout: TimeInterval = 30
    /// How long the app's counters have to stay unchanged before the previous
    /// interaction counts as finished. See `settle(in:)`.
    private static let quietSeconds: TimeInterval = 1.5
    private static let settlePollSeconds: TimeInterval = 0.5
    /// A ceiling, not an expectation: reaching it means something in the app
    /// never stopped re-rendering, which the phase's own budgets then report.
    private static let settleTimeoutSeconds: TimeInterval = 20
    /// The scene has to resign active and the log's one-second flush has to
    /// land before the app is torn down.
    private static let flushSeconds: TimeInterval = 2
    private static let traceTimeout: TimeInterval = 40
    private static let simulatedAltitude: CLLocationDistance = 535
    private static let simulatedAccuracy: CLLocationAccuracy = 5
    /// Slow enough that a 22 m step reads as a walk rather than a sprint the
    /// recorder would reject — see `RecordingFixPolicy`.
    private static let paceSeconds: TimeInterval = 4
    private static let recordedTrace = [
        CLLocationCoordinate2D(latitude: 47.71840, longitude: 12.83180),
        CLLocationCoordinate2D(latitude: 47.71860, longitude: 12.83180),
        CLLocationCoordinate2D(latitude: 47.71880, longitude: 12.83180),
        CLLocationCoordinate2D(latitude: 47.71900, longitude: 12.83180),
    ]

    /// Named on every printed line so one report can hold every scenario.
    private var scenario = ""
    private static let browsingGestures = 3
    private static let scrubSteps = 9
    private static let dragPressSeconds: TimeInterval = 0.1
    private static let launchIterations = 3

    // MARK: - Idle

    /// The cheapest possible regression to catch and the most expensive one to
    /// live with: a screen that re-renders while the user is doing nothing at
    /// all. On a hike that is battery spent on an unchanged picture.
    @MainActor
    func testIdleCostsNothing() {
        let app = launch(
            scenario: "idle",
            arguments: ["--ui-test-import-gpx=\(Self.gpxFixture)"]
        )
        awaitImportedHike(in: app)
        // The import settles asynchronously; measuring from the moment it
        // lands would count the tail of that work as idle cost.
        settle(in: app)

        let idleSeconds: TimeInterval = 6
        let idle = measurePhase(named: "idle", in: app, seconds: idleSeconds) {
            // Deliberately nothing: the phase is the absence of interaction.
        }

        assertNoMoreThan(2, of: "OpenHikesViewBody", in: idle, phase: "idle")
        assertNoMoreThan(2, of: "MapUpdateCalled", in: idle, phase: "idle")
        assertNoMoreThan(2, of: "MapSheetBody", in: idle, phase: "idle")
        assertNoMoreThan(2, of: "MapSheetHikesBody", in: idle, phase: "idle")
        assertNoMoreThan(0, of: "MapRouteRebuilt", in: idle, phase: "idle")
        assertNoStall(in: idle, phase: "idle")
        finish()
    }

    // MARK: - Map browsing

    /// Panning and zooming is the app's most common interaction. MapKit
    /// redraws either way; what must not happen is SwiftUI re-rendering the
    /// sheet and the root for a gesture that never leaves the map.
    @MainActor
    func testMapBrowsingDoesNotReRenderTheSheet() {
        let app = launch(
            scenario: "map-browsing",
            arguments: ["--ui-test-import-gpx=\(Self.gpxFixture)"]
        )
        awaitImportedHike(in: app)
        settle(in: app)

        let map = element("trail-map", in: app)
        let browsing = measurePhase(named: "browsing", in: app, seconds: 0) {
            for _ in 0..<Self.browsingGestures {
                map.swipeUp()
                map.swipeLeft()
                map.pinch(withScale: 2, velocity: 1)
                map.pinch(withScale: 0.5, velocity: -1)
            }
        }

        assertNoMoreThan(4, of: "OpenHikesViewBody", in: browsing, phase: "browsing")
        assertNoMoreThan(4, of: "MapSheetBody", in: browsing, phase: "browsing")
        // The hike list, added after a run showed it rebuilding four times for
        // a gesture that changes no hike. Panning is the one interaction a
        // walker performs constantly, so a list rebuild here is not a rounding
        // error — it is the cost of navigating, multiplied by the whole hike.
        assertNoMoreThan(4, of: "MapSheetHikesBody", in: browsing, phase: "browsing")
        assertNoMoreThan(0, of: "MapRouteRebuilt", in: browsing, phase: "browsing")
        assertNoMoreThan(0, of: "MapViewCreated", in: browsing, phase: "browsing")
        finish()
    }

    // MARK: - Offline

    /// The claim the app is built around, asserted rather than assumed: with
    /// no connection, browsing the map opens no connection *and does not try*.
    ///
    /// Trying is the expensive failure. A tile load that reaches `URLSession`
    /// and fails wakes the radio, and a map draw pass asks for every visible
    /// tile — so an app that merely fails gracefully offline still burns a
    /// walker's battery scanning for a network on every pan. What this asserts
    /// is that `TileNetworkPolicy` refuses first, in-process.
    ///
    /// `--ui-test-offline` also gives this launch an empty tile root. Without
    /// that the scenario passes for the wrong reason on any machine where an
    /// earlier run has already cached the region: no miss, so no fetch to
    /// refuse, so nothing tested.
    @MainActor
    func testOfflineBrowsingOpensNoConnection() {
        let app = launch(
            scenario: "offline-browsing",
            arguments: [
                "--ui-test-offline",
                "--ui-test-import-gpx=\(Self.gpxFixture)",
            ]
        )
        awaitImportedHike(in: app)
        settle(in: app)

        let map = element("trail-map", in: app)
        // The refusals happen on the *first* draw, before any gesture: the
        // renderer keeps a failure log, so a tile it could not load is not
        // asked for again. Read as an absolute rather than a phase delta,
        // because a phase delta of zero is the point.
        let atRest = counters(in: app)
        XCTAssertGreaterThanOrEqual(
            atRest.value(of: "TileFetchSuppressed"),
            1,
            "the map never wanted a tile, so nothing about the policy was tested"
        )

        let browsing = measurePhase(named: "offline-browsing", in: app, seconds: 0) {
            for _ in 0..<Self.browsingGestures {
                map.swipeUp()
                map.swipeLeft()
                map.pinch(withScale: 2, velocity: 1)
                map.pinch(withScale: 0.5, velocity: -1)
            }
        }

        assertNoMoreThan(0, of: "TileNetworkFetch", in: browsing, phase: "offline-browsing")
        assertNoMoreThan(0, of: "WeatherFetch", in: browsing, phase: "offline-browsing")
        assertNoMoreThan(0, of: "TrailGraphFetch", in: browsing, phase: "offline-browsing")
        // And the pans did not even re-ask. This is the part that costs a
        // battery if it regresses: seventeen seconds of gestures over a region
        // with no tiles must not become seventeen seconds of doomed loads, one
        // per visible tile per draw pass. The failure log in
        // `CachingTileOverlayRenderer` is what makes this zero rather than
        // hundreds, and nothing else asserts that it works.
        assertNoMoreThan(0, of: "TileFetchSuppressed", in: browsing, phase: "offline-browsing")
        // The map is still usable while all that is refused. Offline is a
        // degraded map, not a frozen app.
        assertNoStall(in: browsing, phase: "offline-browsing")
        XCTAssertEqual(
            counters(in: app).value(of: "TileNetworkFetch"),
            0,
            "no connection was opened at any point in the run"
        )
        finish()
    }

    // MARK: - Background recording

    /// The way the app is actually used for six hours: recording, in a pocket,
    /// screen off.
    ///
    /// Foreground per-fix cost is what `testLiveRecordingCostPerFix` bounds,
    /// and it is the wrong number for a hike — a walker looks at the screen
    /// for seconds at a time and walks for hours. Backgrounded, every SwiftUI
    /// body evaluation is pure waste: nothing it produces is on screen. The
    /// budget here is therefore not "small", it is "none", with enough slack
    /// for the single pass the system runs as the app resigns.
    @MainActor
    func testBackgroundRecordingCostsNothingPerFix() {
        let app = launch(
            scenario: "background-recording",
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph=\(Self.trailGraphFixture)",
            ]
        )
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.recordedTrace[0])
        defer { XCUIDevice.shared.location = nil }
        app.activate()
        app.tap()

        let recordButton = element("record-hike-button", in: app)
        XCTAssertTrue(recordButton.waitForExistence(timeout: Self.existenceTimeout))
        recordButton.tap()
        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: Self.existenceTimeout))
        settle(in: app)

        let before = counters(in: app)
        let started = Date().timeIntervalSince1970

        XCUIDevice.shared.press(.home)
        // Fixes delivered blind: the counter probe lives in the app's
        // accessibility tree, and reading it would foreground the app, which
        // is the one thing this scenario must not do.
        for coordinate in Self.recordedTrace.dropFirst() {
            Thread.sleep(forTimeInterval: Self.paceSeconds)
            setSimulatedLocation(coordinate)
        }
        Thread.sleep(forTimeInterval: Self.flushSeconds)

        app.activate()
        XCTAssertTrue(points.waitForExistence(timeout: Self.existenceTimeout))
        let after = counters(in: app)
        printPhase("background-recording", from: started, to: Date().timeIntervalSince1970)

        let delta = PerformanceCounterDelta(before: before, after: after)
        report(delta, phase: "background-recording", perEvent: "LiveFixAccepted")

        let fixes = delta.count(of: "LiveFixAccepted")
        XCTAssertGreaterThan(fixes, 0, "no fix was recorded while backgrounded")
        // Asserted against scene transitions rather than against a constant.
        // Leaving and re-entering the foreground costs one pass through the
        // hierarchy and always will; what must not happen is a *fix* costing
        // one. Dividing by the fix count would make this test pass more easily
        // the longer the walk, which is backwards — so the budget is the
        // number of transitions, and it holds for three fixes or three
        // thousand.
        let transitions = delta.count(of: "ScenePhaseChanged")
        XCTAssertGreaterThan(transitions, 0, "the app never actually backgrounded")
        for body in ["OpenHikesViewBody", "MapSheetHikesBody", "RecordingBody", "MapSheetBody"] {
            XCTAssertLessThanOrEqual(
                delta.count(of: body),
                transitions,
                "\(body) ran \(delta.count(of: body)) times for \(transitions) scene "
                    + "transitions and \(fixes) fixes — a backgrounded fix is re-rendering"
            )
        }
        // The trace still has to be captured — a backgrounded app that stops
        // recording would score perfectly above and lose the hike.
        assertRatio(atMost: 2.5, of: "RecordingTailRebuilt", per: fixes, in: delta)
        // …but it must not be *drawn*. There is no map on screen to draw it
        // on, and an `MKPolyline` rebuild plus an overlay swap per fix, for
        // every fix of a six-hour walk, is work whose entire output is
        // discarded. What is left is the single catch-up pass on return, which
        // draws an hour of pocket walking for the price of one fix.
        XCTAssertLessThanOrEqual(
            delta.count(of: "MapRecordingTraceApplied"),
            transitions,
            "the recording trace was drawn \(delta.count(of: "MapRecordingTraceApplied")) "
                + "times for \(fixes) backgrounded fixes — it should be caught up once"
        )
        finish()
    }

    // MARK: - Chart scrubbing

    /// Dragging along the elevation profile moves a marker on the map at touch
    /// frequency. The whole `RouteHighlight`/`MapCoordinator` arrangement
    /// exists so that costs one annotation move — not a root re-render, and
    /// not a rebuilt route polyline.
    ///
    /// Measured as two phases because they are two different questions. The
    /// drag is the gesture a person actually performs, and it is the one the
    /// render-isolation design is meant to keep cheap. The discrete taps are
    /// here to exercise the start/stop edges of the scrub, which is where a
    /// state change would leak upward if one were going to.
    @MainActor
    func testChartScrubbingStaysInsideTheChart() {
        let app = launch(
            scenario: "chart-scrub",
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-import-gpx=\(Self.gpxFixture)",
            ]
        )
        awaitImportedHike(in: app)
        app.staticTexts[Self.importedHikeTitle].tap()
        XCTAssertTrue(
            app.navigationBars[Self.importedHikeTitle]
                .waitForExistence(timeout: Self.existenceTimeout)
        )
        let chart = element("elevation-chart", in: app)
        XCTAssertTrue(
            chart.waitForExistence(timeout: Self.existenceTimeout),
            "the hike detail should draw its profile"
        )
        warmAccessibilityTree(around: chart, in: app)

        let taps = measurePhase(named: "scrub-taps", in: app, seconds: 0) {
            for step in 1...Self.scrubSteps {
                let fraction = Double(step) / Double(Self.scrubSteps + 1)
                let point = chart.coordinate(
                    withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)
                )
                point.tap()
            }
        }
        settle(in: app)

        let drag = measurePhase(named: "scrub-drag", in: app, seconds: 0) {
            let start = chart.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)
            )
            let end = chart.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            )
            start.press(forDuration: Self.dragPressSeconds, thenDragTo: end)
        }

        // The drag is the strict one: a continuous scrub must not escape the
        // chart at all.
        assertNoMoreThan(0, of: "OpenHikesViewBody", in: drag, phase: "scrub-drag")
        assertNoMoreThan(0, of: "MapSheetBody", in: drag, phase: "scrub-drag")
        assertNoMoreThan(0, of: "MapRouteRebuilt", in: drag, phase: "scrub-drag")
        assertNoMoreThan(2, of: "HikeDetailBody", in: drag, phase: "scrub-drag")
        assertAtLeast(
            Double(Self.scrubSteps),
            of: "ElevationChartBody",
            in: drag,
            phase: "scrub-drag"
        )

        // Each tap is a complete scrub cycle, so a handful of edge renders is
        // expected; what must not happen is the route being rebuilt or the
        // detail re-preparing itself.
        assertNoMoreThan(0, of: "MapRouteRebuilt", in: taps, phase: "scrub-taps")
        assertNoMoreThan(0, of: "HikeDetailPrepared", in: taps, phase: "scrub-taps")
        finish()
    }

    // MARK: - Live recording

    /// The scenario the whole app is judged on: fixes arriving while the
    /// screen is up. Every count here is per accepted fix, which is what makes
    /// a per-fix cost that grows with the recording visible as a ratio rather
    /// than as a number nobody can calibrate.
    @MainActor
    func testLiveRecordingCostPerFix() {
        let app = launch(
            scenario: "recording",
            arguments: [
                "--ui-test-expanded-sheet",
                "--ui-test-enable-location",
                "--ui-test-trail-graph=\(Self.trailGraphFixture)",
            ]
        )
        // Deliberately no `resetAuthorizationStatus(for: .location)`. Resetting
        // is what forces the permission dialog, and a dialog that goes
        // unhandled costs the whole scenario — the recorder receives no fixes
        // and the run reports nothing rather than failing loudly.
        // `Scripts/run-performance-tests.sh` grants the permission out-of-band;
        // the monitor below remains as a fallback.
        addLocationPermissionMonitor()
        setSimulatedLocation(Self.recordedTrace[0])
        defer { XCUIDevice.shared.location = nil }
        app.activate()
        app.tap()

        let recordButton = element("record-hike-button", in: app)
        XCTAssertTrue(recordButton.waitForExistence(timeout: Self.existenceTimeout))
        recordButton.tap()
        XCTAssertTrue(
            app.navigationBars["Record Hike"]
                .waitForExistence(timeout: Self.existenceTimeout)
        )

        let points = element("recording-point-count", in: app)
        XCTAssertTrue(points.waitForExistence(timeout: Self.existenceTimeout))
        settle(in: app)

        let before = counters(in: app)
        let started = Date().timeIntervalSince1970
        walkRecordedTrace(in: app, points: points)
        let after = counters(in: app)
        printPhase("recording", from: started, to: Date().timeIntervalSince1970)

        let delta = PerformanceCounterDelta(before: before, after: after)
        let fixes = delta.count(of: "LiveFixAccepted")
        XCTAssertGreaterThan(fixes, 0, "the recorder never accepted a fix, so nothing was measured")
        report(delta, phase: "recording", perEvent: "LiveFixAccepted")

        // Two trace publications per fix, not one, and that is correct rather
        // than tolerated: the raw coordinate is drawn the moment the fix lands
        // so the line keeps up with the walker, and the asynchronous trail
        // match replaces it with snapped geometry when it returns. A budget of
        // 1 would fail permanently and teach everyone to ignore this test; the
        // number worth defending is that it stays *two* and does not grow.
        assertRatio(atMost: 2.5, of: "RecordingTailRebuilt", per: fixes, in: delta)
        assertRatio(atMost: 2.5, of: "MapRecordingTraceApplied", per: fixes, in: delta)
        // The root view, the sheet and the hike list are the ones that must not
        // move: a recording writes to its draft `Hike`, and a `@Query` has no
        // per-property granularity, so this is exactly where a per-fix list
        // rebuild would appear.
        assertRatio(atMost: 1.5, of: "OpenHikesViewBody", per: fixes, in: delta)
        assertRatio(atMost: 1.5, of: "MapSheetHikesBody", per: fixes, in: delta)
        assertRatio(atMost: 0.5, of: "MapRouteRebuilt", per: fixes, in: delta)
        assertNoStall(in: delta, phase: "recording")
        finish()
    }

    // MARK: - XCTest metrics

    @MainActor
    func testLaunchAndSteadyStateResourceMetrics() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-test-import-gpx=\(Self.gpxFixture)",
        ]
        let options = XCTMeasureOptions()
        options.iterationCount = Self.launchIterations

        // `XCTHitchMetric` is deliberately absent: it harvests frame data from
        // an OS signpost stream the Simulator never emits, and asking for it
        // there doesn't degrade — it raises inside `harvestData`, failing the
        // test for a reason that has nothing to do with the app. Hitches are a
        // device measurement; on the Simulator the counter budgets above are
        // the substitute.
        //
        // There is no `stopMeasuring()` below for the same family of reason:
        // `XCTApplicationLaunchMetric` derives its number from the launch
        // signpost interval, and ending the measurement by hand cuts that
        // interval off mid-flight, leaving the metric with no data to harvest.
        // The block therefore has to end naturally, at the point the app is
        // responsive.
        measure(
            metrics: [
                XCTApplicationLaunchMetric(waitUntilResponsive: true),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
            ],
            options: options
        ) {
            app.launch()
            XCTAssertTrue(
                app.staticTexts[Self.importedHikeTitle]
                    .waitForExistence(timeout: Self.existenceTimeout),
                "the measured launch never reached a usable first screen"
            )
            app.terminate()
        }
    }

}

// MARK: - Phases

private extension PerformanceUITests {
    @MainActor
    func counters(in app: XCUIApplication) -> PerformanceCounters {
        let probe = element(Self.probeIdentifier, in: app)
        XCTAssertTrue(
            probe.waitForExistence(timeout: Self.existenceTimeout),
            "the app was not launched with --ui-test-performance-log"
        )
        return PerformanceCounters(rawValue: probe.value as? String ?? "")
    }

    /// Runs `body`, optionally holds still for `seconds` afterwards, and
    /// returns what the app's counters did across the whole window.
    @MainActor
    func measurePhase(
        named phase: String,
        in app: XCUIApplication,
        seconds: TimeInterval,
        _ body: () -> Void
    ) -> PerformanceCounterDelta {
        let before = counters(in: app)
        let started = Date().timeIntervalSince1970
        body()
        if seconds > 0 {
            Thread.sleep(forTimeInterval: seconds)
        }
        let after = counters(in: app)
        printPhase(phase, from: started, to: Date().timeIntervalSince1970)
        let delta = PerformanceCounterDelta(before: before, after: after)
        report(delta, phase: phase, perEvent: nil)
        return delta
    }

    /// Performs one throwaway interaction with `element`, then waits for the
    /// app to go quiet again.
    ///
    /// The first *interaction* with a newly presented screen is not a free
    /// observation. Tapping requires XCUITest to hit-test against a fresh,
    /// fully resolved snapshot of a hierarchy it has not described before, and
    /// SwiftUI evaluates bodies to answer. Merely reading a frame or counting
    /// descendants does not pay that cost — only an interaction does, which is
    /// why this warms with a real tap.
    ///
    /// Measured without this, the chart scrub appeared to re-render
    /// `HikeDetailBody` five times when the drag itself accounts for two, and
    /// whether it did depended on where the snapshot happened to land relative
    /// to the baseline reading — the same run reported 2 and 5 on consecutive
    /// attempts. Paying the cost before the baseline is what makes the phase's
    /// numbers both attributable and repeatable.
    @MainActor
    func warmAccessibilityTree(
        around element: XCUIElement,
        in app: XCUIApplication
    ) {
        let centre = element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        centre.tap()
        settle(in: app)
    }

    /// Waits for whatever the last interaction set off to finish, so a phase
    /// measures its own work rather than the previous one's tail.
    ///
    /// Deliberately not a fixed sleep. SwiftUI settles after a gesture in a
    /// number of passes nobody can predict from the test side — a sheet detent
    /// animation, a `.task` resolving, a detail view's async prepare — and a
    /// constant long enough for the slowest of those on the slowest machine is
    /// a constant that wastes seconds on every other run. Polling the app's own
    /// counters asks the only question that matters: has anything re-rendered
    /// recently? When the answer has been no for `quietSeconds`, the previous
    /// phase is genuinely over.
    @MainActor
    func settle(in app: XCUIApplication) {
        var previous = counters(in: app)
        var quietSince = Date()
        let deadline = Date().addingTimeInterval(Self.settleTimeoutSeconds)

        while Date() < deadline {
            Thread.sleep(forTimeInterval: Self.settlePollSeconds)
            let current = counters(in: app)
            if current.isEquivalent(to: previous) {
                if Date().timeIntervalSince(quietSince) >= Self.quietSeconds {
                    return
                }
            } else {
                previous = current
                quietSince = Date()
            }
        }
    }

    /// Backgrounding is what makes the app flush its log; terminating without
    /// it loses the last second of the scenario.
    @MainActor
    func finish() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: Self.flushSeconds)
    }
}

// MARK: - Assertions and reporting

private extension PerformanceUITests {
    /// The counterpart to `assertNoMoreThan`: proof that the gesture reached
    /// the app at all. Without it a phase that silently failed to touch
    /// anything would satisfy every budget above it by doing nothing.
    func assertAtLeast(
        _ minimum: Double,
        of name: String,
        in delta: PerformanceCounterDelta,
        phase: String
    ) {
        let observed = delta.count(of: name)
        XCTAssertGreaterThanOrEqual(
            observed,
            minimum,
            "\(name) ran \(observed) times during \(phase); the gesture may not have landed"
        )
    }

    func assertNoMoreThan(
        _ limit: Double,
        of name: String,
        in delta: PerformanceCounterDelta,
        phase: String
    ) {
        let observed = delta.count(of: name)
        XCTAssertLessThanOrEqual(
            observed,
            limit,
            "\(name) ran \(observed) times during \(phase), budget \(limit)"
        )
    }

    func assertRatio(
        atMost limit: Double,
        of name: String,
        per events: Double,
        in delta: PerformanceCounterDelta
    ) {
        guard events > 0 else { return }
        let ratio = delta.count(of: name) / events
        XCTAssertLessThanOrEqual(
            ratio,
            limit,
            "\(name) ran \(ratio) times per accepted fix, budget \(limit)"
        )
    }

    func assertNoStall(in delta: PerformanceCounterDelta, phase: String) {
        let stalls = delta.count(of: "MainThread")
        XCTAssertEqual(
            stalls,
            0,
            "the main thread stalled \(stalls) times during \(phase)"
        )
    }

    /// Everything the phase saw, printed for the generated report — including
    /// the counters no assertion covers, since an unexplained new name in this
    /// list is itself a finding.
    func report(
        _ delta: PerformanceCounterDelta,
        phase: String,
        perEvent: String?
    ) {
        let basis = perEvent.map { delta.count(of: $0) } ?? 0
        for name in delta.names where delta.count(of: name) > 0 {
            let count = delta.count(of: name)
            let ratio = basis > 0 ? "\(count / basis)" : ""
            print("PERF-COUNT\t\(scenario)\t\(phase)\t\(name)\t\(count)\t\(ratio)")
        }
    }

    func printPhase(_ phase: String, from start: Double, to end: Double) {
        print("PERF-PHASE\t\(scenario)\t\(phase)\t\(start)\t\(end)")
    }
}

// MARK: - Launching

private extension PerformanceUITests {
    @MainActor
    func launch(scenario: String, arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        self.scenario = scenario
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--ui-test-performance-log=\(scenario)",
        ] + arguments
        // Explicit rather than inherited from the test plan: a UI test's app is
        // launched by this process, so the plan's environment reaches the
        // runner and not the app under test.
        app.launchEnvironment["RENDER_SIGNPOST_LOG"] = "1"
        app.launch()
        return app
    }

    @MainActor
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func awaitImportedHike(in app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts[Self.importedHikeTitle]
                .waitForExistence(timeout: Self.existenceTimeout),
            "the fixture hike should import"
        )
    }
}

// MARK: - Location

private extension PerformanceUITests {
    @MainActor
    func addLocationPermissionMonitor() {
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            guard alert.buttons.count >= 2 else { return false }
            alert.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    @MainActor
    func setSimulatedLocation(_ coordinate: CLLocationCoordinate2D) {
        XCUIDevice.shared.location = XCUILocation(
            location: CLLocation(
                coordinate: coordinate,
                altitude: Self.simulatedAltitude,
                horizontalAccuracy: Self.simulatedAccuracy,
                verticalAccuracy: Self.simulatedAccuracy,
                timestamp: .now
            )
        )
    }

    /// Steps the simulator through the fixture trace, waiting for the recorder
    /// to accept each coordinate. A static simulated location is delivered
    /// once, so a fix the recorder turns down has to be handed to it again —
    /// the same contract `OpenHikesUITests` works under.
    @MainActor
    func walkRecordedTrace(in app: XCUIApplication, points: XCUIElement) {
        for (index, coordinate) in Self.recordedTrace.enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: Self.paceSeconds)
                setSimulatedLocation(coordinate)
            }
            XCTAssertTrue(
                waitForPointCount(atLeast: index + 1, in: points) {
                    self.setSimulatedLocation(coordinate)
                },
                "the recorder never accepted fix \(index + 1)"
            )
        }
    }

    @MainActor
    func waitForPointCount(
        atLeast count: Int,
        in element: XCUIElement,
        redeliver: () -> Void
    ) -> Bool {
        let deadline = Date().addingTimeInterval(Self.traceTimeout)
        while Date() < deadline {
            if let value = element.value as? String,
               let recorded = Int(value), recorded >= count {
                return true
            }
            Thread.sleep(forTimeInterval: Self.paceSeconds)
            redeliver()
        }
        return false
    }
}
