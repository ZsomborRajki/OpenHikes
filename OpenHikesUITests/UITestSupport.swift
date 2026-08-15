//
//  UITestSupport.swift
//  OpenHikesUITests
//
//  What every class in this bundle needs before it can assert anything: the
//  launch arguments that put the app in a testable state, the fixtures it is
//  driven with, and the handful of lookups and gestures that are the same
//  whether a test is checking behaviour, accessibility or cost.
//
//  These lived in three copies — one per test class — and drifted: the same
//  simulated fix was built with two different altitudes, and a change to how
//  a hike row is exposed had to be found in every file that queried one.
//  Sharing them means a screen that changes shape is fixed once here.
//

import CoreLocation
import XCTest

/// The bundled fixtures UI automation drives the app with, and the numbers
/// that make a simulated walk believable to ``RecordingFixPolicy``.
nonisolated enum UITestFixture {
    /// Imported through `--ui-test-import-gpx`.
    static let gpxName = "ThumseeLoopFast"
    /// The title the fixture GPX imports under.
    static let importedHikeTitle = "Thumsee Loop (fast, simulated)"
    /// Matched against through `--ui-test-trail-graph`, so a review section
    /// does not depend on reaching Overpass.
    static let trailGraphName = "ThumseeRidgePath"

    /// Slow enough that a 22 m step reads as a walk rather than a sprint the
    /// recorder would reject.
    static let paceSeconds: TimeInterval = 4
    static let simulatedAltitude: CLLocationDistance = 535
    static let simulatedAccuracy: CLLocationAccuracy = 5

    /// The trace `OpenHikesUITests` records, east of the bundled trail, which
    /// runs due north along one longitude.
    ///
    /// Mirrors `UITestRecordingFixture` in `OpenHikesTests`, which asserts
    /// that it still snaps onto the bundled graph and produces exactly one
    /// reviewable section — down to the shape of the declaration, so a change
    /// to one is visibly a change to the other. The numbers are duplicated
    /// because this bundle runs out-of-process and cannot import the app.
    static let traceLongitude = 12.83180
    static let traceStartLatitude = 47.71840
    static let traceMiddleLatitude = 47.71860
    static let traceEndLatitude = 47.71880
    /// One point further north, for a scenario that wants a longer walk than
    /// the three the review fixture is pinned to.
    static let traceExtraLatitude = 47.71900

    static var reviewableTrace: [CLLocationCoordinate2D] {
        [traceStartLatitude, traceMiddleLatitude, traceEndLatitude]
            .map(coordinate(atLatitude:))
    }

    static var extendedTrace: [CLLocationCoordinate2D] {
        reviewableTrace + [coordinate(atLatitude: traceExtraLatitude)]
    }

    static func coordinate(
        atLatitude latitude: CLLocationDegrees
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: traceLongitude)
    }

    /// A fix on the fixture trail, for a test that only needs the app to know
    /// where it is.
    static let trailheadLatitude = 47.718420
    static let trailheadLongitude = 12.831774
    static let trailheadCoordinate = CLLocationCoordinate2D(
        latitude: trailheadLatitude,
        longitude: trailheadLongitude
    )
}

// MARK: - Launching

extension XCTestCase {
    /// Builds the app under test with `--ui-testing` already set, which is
    /// what selects the in-memory store and the isolated defaults.
    ///
    /// Not launched here: a caller that has to set `launchEnvironment` — a
    /// test plan's environment reaches the runner, not the app — needs the
    /// instance before it starts.
    @MainActor
    func makeApp(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        return app
    }

    /// Launches and waits for the foreground. `launch()` returning and the app
    /// being there to be queried are not the same event; querying the
    /// accessibility tree too early is what turns into `kAXErrorServerNotFound`
    /// — a failure about the harness wearing the costume of a failure about
    /// the app.
    @MainActor
    @discardableResult func launch(
        _ app: XCUIApplication,
        timeout: TimeInterval = UITestTimeout.launch
    ) -> XCUIApplication {
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: timeout),
            "the app never reached the foreground after launch"
        )
        return app
    }

    /// The common case: build and launch in one step.
    @MainActor
    @discardableResult func launchApp(arguments: [String] = []) -> XCUIApplication {
        launch(makeApp(arguments: arguments))
    }
}

/// Waits long enough for a cold simulator without hiding a hang.
nonisolated enum UITestTimeout {
    static let launch: TimeInterval = 30
    static let existence: TimeInterval = 15
    static let navigation: TimeInterval = 10
    static let trace: TimeInterval = 40
}

// MARK: - Element lookup

extension XCTestCase {
    /// Identifier lookup across every element type, because the identifiers
    /// this app sets land on buttons, static texts, sliders and plain
    /// containers alike.
    @MainActor
    func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// A hike's row in the sheet.
    ///
    /// ``HikeRow`` is deliberately one combined accessibility element — a row
    /// is a single tap target, so a symbol, a badge and a chevron are three
    /// stops that say nothing — which means its title is no longer a static
    /// text of its own. The row is matched by the label it leads with instead.
    @MainActor
    func hikeRow(
        titled title: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "hike-row")
            .matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch
    }

    @MainActor
    @discardableResult func awaitHikeRow(
        titled title: String,
        in app: XCUIApplication,
        timeout: TimeInterval = UITestTimeout.existence
    ) -> XCUIElement {
        let row = hikeRow(titled: title, in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: timeout),
            "the hike \"\(title)\" should be listed in the sheet"
        )
        return row
    }

    /// Opens the fixture hike and waits for its detail view to be pushed.
    @MainActor
    func openHikeDetail(
        in app: XCUIApplication,
        titled title: String = UITestFixture.importedHikeTitle
    ) {
        awaitHikeRow(titled: title, in: app).tap()
        XCTAssertTrue(
            app.navigationBars[title]
                .waitForExistence(timeout: UITestTimeout.navigation),
            "tapping a hike row should push its detail view"
        )
    }
}

// MARK: - Gestures

extension XCTestCase {
    /// Taps a control that may be below the fold. The sheet is half height for
    /// most of these screens, so a control has to be scrolled into reach
    /// before it can be tapped.
    @MainActor
    func scrollToTap(
        _ target: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = UITestTimeout.existence,
        attempts: Int = 5
    ) {
        XCTAssertTrue(target.waitForExistence(timeout: timeout))
        scrollIntoView(target, in: app, attempts: attempts)
        target.tap()
    }

    /// Swipes the screen's scrolling container until the target is reachable.
    ///
    /// A row below the fold is not merely off-screen: SwiftUI builds `List`
    /// and `Form` rows lazily, so it may be absent from the element tree
    /// altogether, which is why this waits on `exists` rather than assuming it.
    @MainActor
    @discardableResult func scrollIntoView(
        _ target: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 8
    ) -> Bool {
        let container = scrollContainer(in: app)
        for _ in 0..<attempts {
            if target.exists, target.isHittable { return true }
            container.swipeUp()
        }
        return target.exists && target.isHittable
    }

    /// The screen's scrolling container, whichever kind SwiftUI built it from.
    /// Falls back to the application itself, which accepts the same swipe.
    @MainActor
    func scrollContainer(in app: XCUIApplication) -> XCUIElement {
        for query in [app.scrollViews, app.collectionViews, app.tables] {
            let first = query.firstMatch
            if first.exists { return first }
        }
        return app
    }

    /// Polls a selection trait rather than sleeping on it: the write goes
    /// through SwiftData and back out through SwiftUI, so "tapped" and
    /// "selected" are not the same instant.
    @MainActor
    func waitUntilSelected(
        _ target: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.isSelected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}

// MARK: - Location

extension XCTestCase {
    /// Accepts whichever "allow" the location prompt offers. Location prompts
    /// put affirmative choices before the final localized denial action.
    @MainActor
    func addLocationPermissionMonitor() {
        addUIInterruptionMonitor(
            withDescription: "Location permission"
        ) { alert in
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
                altitude: UITestFixture.simulatedAltitude,
                horizontalAccuracy: UITestFixture.simulatedAccuracy,
                verticalAccuracy: UITestFixture.simulatedAccuracy,
                timestamp: .now
            )
        )
    }

    /// Steps the simulator through a trace, waiting for the recorder to accept
    /// each coordinate rather than guessing at a fix interval. A static
    /// simulated location is delivered once, so a fix the recorder turns down
    /// — for implied speed or displacement, see `RecordingFixPolicy` — has to
    /// be handed to it again.
    @MainActor
    func walkRecordedTrace(
        _ trace: [CLLocationCoordinate2D],
        countedBy points: XCUIElement,
        pace: TimeInterval = UITestFixture.paceSeconds,
        timeout: TimeInterval = UITestTimeout.trace
    ) {
        for (index, coordinate) in trace.enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: pace)
                setSimulatedLocation(coordinate)
            }
            XCTAssertTrue(
                waitForPointCount(
                    atLeast: index + 1,
                    in: points,
                    pace: pace,
                    timeout: timeout
                ) { self.setSimulatedLocation(coordinate) },
                "the recorder never accepted fix \(index + 1)"
            )
        }
    }

    @MainActor
    func waitForPointCount(
        atLeast count: Int,
        in element: XCUIElement,
        pace: TimeInterval = UITestFixture.paceSeconds,
        timeout: TimeInterval = UITestTimeout.trace,
        redeliver: () -> Void
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String,
               let recorded = Int(value), recorded >= count {
                return true
            }
            Thread.sleep(forTimeInterval: pace)
            redeliver()
        }
        return false
    }

    /// Starts a recording from the sheet and waits for the recording screen.
    /// The app is tapped first because a launch that has just asked for
    /// location leaves the interruption monitor waiting for one event.
    @MainActor
    func startRecording(in app: XCUIApplication) {
        app.tap()
        let recordButton = element("record-hike-button", in: app)
        XCTAssertTrue(
            recordButton.waitForExistence(timeout: UITestTimeout.navigation)
        )
        recordButton.tap()
        XCTAssertTrue(
            app.navigationBars["Record Hike"]
                .waitForExistence(timeout: UITestTimeout.navigation)
        )
    }
}
