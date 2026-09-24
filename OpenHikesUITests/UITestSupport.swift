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

    static var reviewableTrace: [CLLocationCoordinate2D] {
        [traceStartLatitude, traceMiddleLatitude, traceEndLatitude]
            .map(coordinate(atLatitude:))
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

    // swiftlint:disable no_magic_numbers
    /// Points from the fixture GPX itself — its first, sixth, seventh, eighth,
    /// ninth and tenth `<trkpt>`s, 30 to 50 m apart along the trail — so
    /// every fix here is *on* the trail the app is following rather than
    /// near it, and each one extends a walk's coverage. The first four span
    /// 116 m, which is past the 100 m a walk needs to be kept.
    ///
    /// A follow has no speed gate, unlike `RecordingFixPolicy`, so the pace
    /// between them only has to outlast `LocationManager`'s one-publish-a-second
    /// throttle.
    static let trailPoints = [
        trailheadCoordinate,
        CLLocationCoordinate2D(latitude: 47.718598, longitude: 12.831420),
        CLLocationCoordinate2D(latitude: 47.718823, longitude: 12.831149),
        CLLocationCoordinate2D(latitude: 47.719219, longitude: 12.830877),
        CLLocationCoordinate2D(latitude: 47.719317, longitude: 12.830874),
        CLLocationCoordinate2D(latitude: 47.719474, longitude: 12.830948),
    ]
    // swiftlint:enable no_magic_numbers

    /// A fix a kilometre north of the trailhead: far enough that no leg of
    /// the fixture trail is within the follow threshold, so a launch that
    /// starts here has a hike open and no walk started.
    static let offTrailCoordinate = CLLocationCoordinate2D(
        latitude: trailheadLatitude + offTrailOffsetDegrees,
        longitude: trailheadLongitude
    )
    /// About 1.1 km of latitude.
    private static let offTrailOffsetDegrees = 0.01
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
    /// For asserting that something is **not** there.
    ///
    /// Short on purpose, and the reason is the opposite of every other value
    /// here: a wait for an absence pays its whole timeout on the happy path,
    /// so a generous one turns a passing assertion into dead time. It still
    /// has to outlast a screen settling, which is what it is set by.
    static let brief: TimeInterval = 2
    /// How often ``XCTestCase/waitUntil(timeout:_:)`` re-asks. Every query
    /// crosses to the app and back, so polling faster buys nothing and costs
    /// the very contention these waits exist to survive.
    static let pollInterval: TimeInterval = 0.25
}

// MARK: - Waiting

/// How an element's text reads in a failure message, or why it does not.
///
/// A wait that times out is only worth the message it leaves behind: on
/// someone else's machine, or in a `--all` run nobody watched, the observed
/// string is the entire difference between "the screen was in the wrong
/// state" and "the element was never there".
private func quoted(_ text: String?) -> String {
    guard let text else { return "<absent>" }
    return "\"\(text)\""
}

/// What a caller said the assertion was *for*, ahead of what was observed.
/// The observation says which state the screen was in; only this says which
/// state it was supposed to be in and why that matters.
private func prefixed(_ message: String) -> String {
    message.isEmpty ? "" : message + " — "
}

extension XCTestCase {
    /// The one poll loop this bundle needs, and the only sanctioned way to
    /// wait on something that is not plain existence.
    ///
    /// Every wait here re-asks the app rather than sleeping a guessed
    /// duration, per the *No fixed sleeps as barriers* rule in `AGENTS.md`.
    /// The condition is evaluated once more after the deadline, because a
    /// loop that only checks on the way round can give up on a change that
    /// landed within the last poll interval and still report a timeout.
    @MainActor
    func waitUntil(
        timeout: TimeInterval = UITestTimeout.navigation,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: UITestTimeout.pollInterval)
        }
        return condition()
    }

    /// Waits for what an element *says* to contain `text`, and fails naming
    /// what it said instead.
    ///
    /// Existence and content are two events. A phase label, a row's badge and
    /// a progress summary are all drawn after the element holding them is in
    /// the tree, so reading `.label` on the line below `waitForExistence`
    /// asks the question before the answer exists. That race is invisible on
    /// an idle machine and lost regularly under `--all`, where three
    /// simulator clones share one machine's cores.
    ///
    /// Reporting the observed label is the other half. The
    /// `expectation(for:evaluatedWith:)` this replaces timed out with
    /// "unfulfilled expectations" and no clue which state the screen was
    /// actually in.
    @MainActor
    @discardableResult func expectLabel(
        _ element: XCUIElement,
        contains text: String,
        _ message: String = "",
        timeout: TimeInterval = UITestTimeout.navigation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let matched = waitUntil(timeout: timeout) {
            element.exists && element.label.contains(text)
        }
        XCTAssertTrue(
            matched,
            """
            \(prefixed(message))no label contained "\(text)"; \
            it read \(quoted(element.exists ? element.label : nil))
            """,
            file: file,
            line: line
        )
        return matched
    }

    /// Polls an element's value until it differs from `previous`, so a fix is
    /// waited on by the row it moves rather than by a duration.
    @MainActor
    func waitUntilValueChanges(
        from previous: String?,
        on element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        waitUntil(timeout: timeout) {
            element.exists && (element.value as? String) != previous
        }
    }

    /// Polls an element's label until it differs from `previous`.
    ///
    /// Which section a review is showing is drawn as a title and nothing
    /// else, so a Next that redrew without moving is indistinguishable from
    /// one that worked — unless the title is watched for a change.
    @MainActor
    func waitUntilLabelChanges(
        from previous: String,
        on element: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        waitUntil(timeout: timeout) {
            element.exists && element.label != previous
        }
    }
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
    /// A spot nothing in the app answers: the status bar, left of the
    /// Dynamic Island. See ``startRecording(in:)``.
    private static let inertStatusBarX: CGFloat = 0.2
    private static let inertStatusBarY: CGFloat = 0.03

    /// Polls a selection trait rather than sleeping on it: the write goes
    /// through SwiftData and back out through SwiftUI, so "tapped" and
    /// "selected" are not the same instant.
    @MainActor
    func waitUntilSelected(
        _ target: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        waitUntil(timeout: timeout) { target.isSelected }
    }

    /// Taps a control once it is actually there.
    ///
    /// `tap()` does no waiting of its own: it resolves the query, finds
    /// nothing and fails with "No matches found", which reads as a control
    /// the app never drew rather than one the test asked for too early. Use
    /// this for anything that appears *in response* to the previous step —
    /// ``scrollToTap(_:in:timeout:attempts:)`` is the version for a control
    /// that also has to be brought into reach.
    @MainActor
    func tapWhenReady(
        _ target: XCUIElement,
        timeout: TimeInterval = UITestTimeout.navigation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard target.waitForExistence(timeout: timeout) else {
            XCTFail("the control to tap never appeared", file: file, line: line)
            return
        }
        target.tap()
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
        var nextDelivery = Date().addingTimeInterval(pace)
        while Date() < deadline {
            if let value = element.value as? String,
               let recorded = Int(value), recorded >= count {
                return true
            }
            // How often the count is re-read is not how often a fix is
            // re-delivered. Reading at the pace meant a fix accepted a
            // fraction of a second after it was handed over went unnoticed
            // for a whole pace, and a seventeen-fix walk paid that on every
            // one of them — sixty seconds of a hundred-and-fifty-second test.
            if Date() >= nextDelivery {
                redeliver()
                nextDelivery = Date().addingTimeInterval(pace)
            }
            Thread.sleep(forTimeInterval: UITestTimeout.pollInterval)
        }
        return false
    }

    /// Starts a recording from the map's record button and waits for the
    /// recording screen. The app is tapped first because a launch that has
    /// just asked for location leaves the interruption monitor waiting for one
    /// event — and tapped in the status bar, left of the Dynamic Island,
    /// because the middle of the screen is the sheet's grabber, which expands
    /// the sheet and fades out the button this is about to tap.
    @MainActor
    func startRecording(in app: XCUIApplication) {
        let statusBar = CGVector(dx: Self.inertStatusBarX, dy: Self.inertStatusBarY)
        app.coordinate(withNormalizedOffset: statusBar).tap()
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

    /// Confirms a destructive `confirmationDialog` by the title of its
    /// confirming button.
    ///
    /// Found inside the presentation rather than by title for the reason
    /// ``confirmDiscard(in:)`` explains: a plain lookup resolves to whichever
    /// the tree lists first, and the button that raised the dialog is often
    /// that one. `failureMessage` is what a *missing* dialog reads as, which
    /// is the assertion that matters here — these tests exist because the
    /// action used to happen with nothing asked.
    @MainActor
    func confirmDestructive(
        _ title: String,
        in app: XCUIApplication,
        failureMessage: String
    ) {
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
        XCTFail(failureMessage)
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

    /// Replaces everything in a text field, retrying the select-all a busy
    /// machine drops.
    ///
    /// Three taps are select-all when the system reads them as one gesture and
    /// three carets when it does not, and which one happens depends on how
    /// loaded the machine is. Under a three-clone `--all` the new name is
    /// therefore *inserted* into the old one and the screen ends up titled
    /// "Thumsee LoopRenamed Route (fast, simulated)" — a failure that reads as
    /// a broken rename and is nothing of the sort. It was seen four times
    /// across two branches under load and never once on a quiet machine.
    ///
    /// So the gesture is not trusted and its effect is. This is the *No fixed
    /// sleeps as barriers* rule pointed at a gesture rather than a wait: what
    /// is asserted is what the field holds, and a tap that did not take is
    /// simply made again. A field that already reads `text` costs one query
    /// and no taps.
    ///
    /// Not usable to *empty* a field whose placeholder is what it draws when
    /// empty — the value read back is then the placeholder, and a clear cannot
    /// be told from a fill. Replacing is the case that reads back
    /// unambiguously, and is what both callers here do.
    @MainActor
    @discardableResult func replaceText(
        of field: XCUIElement,
        with text: String,
        timeout: TimeInterval = UITestTimeout.navigation
    ) -> Bool {
        waitUntil(timeout: timeout) {
            if field.value as? String == text { return true }
            field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
            field.typeText(text)
            return field.value as? String == text
        }
    }

    /// Confirms an edit with the keyboard's own return key.
    ///
    /// For a field whose screen has no keyboard toolbar, which the hike title
    /// deliberately has not: see the comment on its `submitLabel` for what an
    /// accessory that comes and goes with the field costs. Asking
    /// ``commitKeyboardEdit(in:)`` there spends its whole timeout looking for
    /// a *Done* that is never coming, and then does exactly this.
    @MainActor
    func submitKeyboardEdit(in app: XCUIApplication) {
        app.typeText("\n")
    }

    /// Confirms an edit through the keyboard's own Done button, falling back
    /// to a return key.
    ///
    /// The toolbar button is the reliable one: it calls the commit directly,
    /// where a newline depends on the field having a submit action wired to
    /// it, and lands on whatever has focus if it does not. For a screen that
    /// has no such button, ``submitKeyboardEdit(in:)`` is the one to ask.
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
        // The prompt opens holding a suggested title, so this replaces rather
        // than types — and the replacement is waited on rather than assumed,
        // for the reason `replaceText(of:with:)` gives.
        XCTAssertTrue(
            replaceText(of: field, with: name),
            "the name field should hold \"\(name)\", said "
                + "\"\(field.value as? String ?? "")\""
        )
        namePrompt.buttons["Save"].tap()
    }
}
