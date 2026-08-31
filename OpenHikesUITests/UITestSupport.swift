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

/// The two-trail walk behind the review screen's Previous and Next buttons.
///
/// Those buttons do nothing with one section, and one is all
/// ``UITestFixture/reviewableTrace`` can produce. Two need a walk that snaps,
/// then wanders far enough from any trail for long enough that the matcher
/// leaves it alone — closing the first run — then snaps onto a second trail.
///
/// Mirrors `UITestMultiSectionFixture` in `OpenHikesTests`, which asserts in
/// milliseconds that these numbers still produce exactly two sections. That
/// assertion is why this walk can be trusted: proving it in the simulator
/// means a minute of watching, and a wrong answer arrives as two grey buttons
/// with no explanation attached.
nonisolated enum UITestMultiSectionFixture {
    /// Two disconnected trails, 255 m apart, matched against through
    /// `--ui-test-trail-graph`.
    static let trailGraphName = "ThumseeTwinPaths"
    static let longitude = 12.83180
    static let startLatitude = 47.71840
    /// 22 m per step, which at the four-second pace is a walk rather than a
    /// sprint ``RecordingFixPolicy`` turns down.
    static let latitudeStep = 0.0002
    static let fixCount = 17

    static var trace: [CLLocationCoordinate2D] {
        (0..<fixCount).map { index in
            CLLocationCoordinate2D(
                latitude: startLatitude + latitudeStep * Double(index),
                longitude: longitude
            )
        }
    }
}

/// The tagged graph behind the hike detail screen's Surface and Difficulty
/// sections.
///
/// Both sections are drawn only once OpenStreetMap has answered for the route,
/// so without this they are unreachable from a test — Overpass is not
/// something automation may depend on. The fixture is the imported GPX's own
/// geometry, tagged in three stretches, which is what makes the shares
/// something to assert on rather than one solid block.
///
/// Mirrors `UITestTrailTagFixture` in `OpenHikesTests`, which pins the
/// coverage and the shares themselves.
nonisolated enum UITestTrailTagFixture {
    static let trailGraphName = "ThumseeLoopTrails"
    /// The spoken share list the difficulty bar carries as its value. Any one
    /// of the graded stretches is enough to know the bar is describing real
    /// tags rather than an empty breakdown.
    static let spokenDifficulty = "Hiking"
    static let spokenSurface = "Gravel"
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

    /// A photo tile in a hike's gallery, found by the position it reports
    /// rather than by the identifier it carries — that identifier is the
    /// photo's UUID, which is generated at import and cannot be known from out
    /// of process.
    @MainActor
    func photoTile(
        at index: Int,
        of count: Int,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "Photo \(index) of \(count)"
                )
            )
            .firstMatch
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
            if isReachable(target, in: app) { return true }
            container.swipeUp()
        }
        return isReachable(target, in: app)
    }

    /// Whether `target` can actually be aimed at, rather than merely touched.
    ///
    /// `isHittable` alone is not that question. XCUITest clamps an element's
    /// hit point into whatever part of it is on screen, so a row hanging off
    /// the bottom edge by all but a few points still answers yes — and a
    /// `coordinate(withNormalizedOffset:)` tap, which is computed from the
    /// *unclamped* frame, then lands outside the window and silently does
    /// nothing. That is exactly how the settings toggle test failed: the
    /// collection view had rendered the row at the fold, the search returned
    /// on its first iteration without swiping at all, and the trailing-edge
    /// tap went nowhere. Requiring the centre to be on screen is what makes
    /// the two agree.
    @MainActor
    func isReachable(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        guard target.exists, target.isHittable else { return false }
        let frame = target.frame
        return app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
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

    /// Scrolls looking for something that may not be on the screen *yet*.
    ///
    /// ``scrollIntoView(_:in:attempts:)`` assumes the target already exists
    /// somewhere in the scroll view and only has to be reached. A section that
    /// appears once an off-main analysis finishes is a different problem: it
    /// can arrive after the search has given up, and it can arrive *above*
    /// where the search has scrolled to. So this keeps looking until a
    /// deadline, and reverses every few swipes rather than pinning itself to
    /// the bottom.
    @MainActor
    @discardableResult func scrollUntilVisible(
        _ target: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = UITestTimeout.existence
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var swipes = 0
        while Date() < deadline {
            if isReachable(target, in: app) { return true }
            let container = scrollContainer(in: app)
            if swipes % (Self.swipesPerSweep * 2) < Self.swipesPerSweep {
                container.swipeUp()
            } else {
                container.swipeDown()
            }
            swipes += 1
        }
        return isReachable(target, in: app)
    }

    /// Far enough to cross a hike's detail screen, short enough that a section
    /// arriving late is not missed by a search stuck at the far end of it.
    private static let swipesPerSweep = 4

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

    /// Confirms the "Discard this recording?" dialog.
    ///
    /// The confirming button carries the same title as the one that raised it,
    /// so it has to be found inside the presentation rather than by title: a
    /// plain lookup resolves to whichever the tree happens to list first,
    /// which on a good day is the button already tapped.
    @MainActor
    func confirmDiscard(in app: XCUIApplication) {
        let title = "Discard Recording"
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
        XCTFail("discarding should ask before throwing a walk away")
    }

    /// Taps whatever the current screen's back button is.
    ///
    /// Addressed by position rather than by title: a back button is labelled
    /// with the screen behind it, which changes with every push this bundle
    /// makes and is empty for the map.
    @MainActor
    func popScreen(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            back.waitForExistence(timeout: UITestTimeout.navigation),
            "the pushed screen should offer a way back"
        )
        back.tap()
    }

    /// Confirms an edit through the keyboard's own Done button, falling back
    /// to a return key.
    ///
    /// The toolbar button is the reliable one: it calls the commit directly,
    /// where a newline depends on the field having a submit action wired to
    /// it, and lands on whatever has focus if it does not.
    @MainActor
    func commitKeyboardEdit(in app: XCUIApplication) {
        let toolbarDone = app.toolbars.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: UITestTimeout.navigation) {
            toolbarDone.tap()
            return
        }
        app.typeText("\n")
    }

    /// Stops a recording and names it, which is where every walk this bundle
    /// records either ends or moves on to review.
    ///
    /// The name is typed before either happens, so a test that finds it on the
    /// saved hike afterwards has also proved the review step carried it
    /// through.
    @MainActor
    func stopRecording(named name: String, in app: XCUIApplication) {
        app.buttons["Stop"].tap()
        let namePrompt = app.alerts["Name Your Hike"]
        XCTAssertTrue(
            namePrompt.waitForExistence(timeout: UITestTimeout.navigation)
        )
        let field = namePrompt.textFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: UITestTimeout.navigation)
        )
        field.tap()
        if let draft = field.value as? String, !draft.isEmpty {
            field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        }
        field.typeText(name)
        XCTAssertEqual(field.value as? String, name)
        namePrompt.buttons["Save"].tap()
    }
}
