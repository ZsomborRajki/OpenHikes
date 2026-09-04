//
//  RenderIsolationTests.swift
//  OpenHikesTests
//
//  The app's central performance idea (the "Preserve render isolation"
//  convention in `.github/copilot-instructions.md`) is that high-frequency
//  state lives in `@Observable` reference types that the owning views never
//  read in their own `body`, so a GPS fix or a sheet drag moves one
//  annotation instead of re-diffing a view tree. That only holds if two
//  things are true, and neither is checkable by reading the code:
//
//  * an observer really is notified per write — including writes that don't
//    change the value, which is why the coordinate-typed publishers compare
//    before assigning (`RouteHighlight.move(to:)`, `LocationManager.publish`);
//    and
//  * observing one property really doesn't wake observers of another.
//
//  Neither is true unconditionally, and the two halves point opposite ways:
//  Observation *does* filter a write that compares equal on an `Equatable`
//  property, and SwiftData's `@Model` does *not*. Several suites' zero
//  assertions are really assertions about one or the other, so both are pinned
//  here — see `Observation cost`.
//
//  So the tests here pin the *notification* behaviour these views are tuned
//  against, and then check the producers that feed them at high frequency.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import SwiftUI
import Testing

/// Counts `withObservationTracking` notifications, re-registering after each
/// one exactly the way `MapView.Coordinator` does.
final class ObservationCounter {
    private(set) var count = 0
    private var track: (() -> Void)?

    /// - Parameter read: the property access to observe, mirroring what the
    ///   corresponding view or coordinator reads.
    init(_ read: @escaping () -> Void) {
        track = { [weak self] in
            withObservationTracking {
                read()
            } onChange: {
                Task { @MainActor in
                    guard let self else { return }
                    self.count += 1
                    self.track?()
                }
            }
        }
        track?()
    }

    /// Lets the queued re-registrations run. Observation delivers its change
    /// callback synchronously but the re-registration hops through a `Task`,
    /// same as in the app.
    ///
    /// Deliberately without a condition — the one wait in these suites that
    /// stays best-effort. Half its callers wait for the count to rise and the
    /// other half assert that it did *not*, and "the count has reached N"
    /// would satisfy the first kind the instant the notification it expects
    /// lands, returning before a *spurious* extra one could arrive. That turns
    /// the regression this counter exists to catch into a pass, which is worse
    /// than the load-sensitivity naming it would remove.
    func settle() async {
        await settleDelegateHop()
    }
}

@Suite("Recording isolation")
struct RecordingIsolationTests {
    @Test("a fix wakes only the recording leaves that read its state")
    func recordingStateIsSplitByConcern() async {
        let stats = RecordingStats()
        let trace = RecordingTrace()
        let distanceCounter = ObservationCounter { _ = stats.distanceMeters }
        let pointCounter = ObservationCounter { _ = stats.pointCount }
        let traceCounter = ObservationCounter { _ = trace.revision }
        await distanceCounter.settle()

        stats.distanceMeters = 42
        trace.append(
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        )
        await distanceCounter.settle()

        #expect(distanceCounter.count == 1)
        #expect(pointCounter.count == 0)
        #expect(traceCounter.count == 1)
    }

    @Test("a live match revises only the provisional trace generation")
    func liveMatchReplacesTheProvisionalTail() {
        let trace = RecordingTrace()
        let generation = trace.generation
        trace.append(
            CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            provisional: true
        )
        trace.append(
            CLLocationCoordinate2D(latitude: 47.6302, longitude: 12.86),
            provisional: true
        )

        #expect(trace.applyLiveMatch(
            committing: [
                CLLocationCoordinate2D(
                    latitude: 47.63,
                    longitude: 12.8599
                ),
            ],
            provisional: [
                CLLocationCoordinate2D(
                    latitude: 47.63,
                    longitude: 12.8599
                ),
                CLLocationCoordinate2D(
                    latitude: 47.6302,
                    longitude: 12.8599
                ),
            ],
            expectedGeneration: generation
        ))
        #expect(trace.tail.count == 2)
        #expect(trace.tail.allSatisfy { coord in
            abs(coord.longitude - 12.8599) < 0.000001
        })

        trace.replace(with: [])
        #expect(!trace.applyLiveMatch(
            committing: [],
            provisional: [
                CLLocationCoordinate2D(
                    latitude: 47.64,
                    longitude: 12.85
                ),
            ],
            expectedGeneration: generation
        ))
        #expect(trace.tail.isEmpty)
    }

    /// `RecordingView.body` and the whole hikes sheet (via
    /// `HikeRecorder.isActive`) read `phase`, and the accepted-fix path in
    /// `HikeRecorder` touches it on every fix. Those bodies are budgeted at
    /// one invalidation per phase change, not one per fix, so a fix that
    /// leaves the phase alone must wake nothing.
    @Test("a fix that doesn't change the phase doesn't wake a body reading it")
    func steadyRecordingDoesNotInvalidatePhaseReaders() async throws {
        let container = try Fixture.modelContainer()
        let source = IsolationRecordingSource()
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "recording-isolation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = HikeRecorder(
            container: container,
            source: source,
            journalDirectory: directory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        await recorder.start()

        let phaseCounter = ObservationCounter { _ = recorder.phase }
        await phaseCounter.settle()

        for step in 1...5 {
            clock.advance(by: 10)
            source.deliver(
                CLLocation(
                    coordinate: CLLocationCoordinate2D(
                        latitude: 47.63 + Double(step) * 0.0002,
                        longitude: 12.86
                    ),
                    altitude: 600,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5,
                    course: 0,
                    speed: 1,
                    timestamp: clock.now
                )
            )
            await phaseCounter.settle()
        }

        #expect(recorder.stats.pointCount == 5)
        #expect(
            phaseCounter.count == 1,
            "only waitingForFix → recording; the four fixes after it change nothing"
        )
    }
}

/// The minimum `RecordingLocationSource` needed to push fixes at a recorder.
private final class IsolationRecordingSource: RecordingLocationSource {
    var authorization: RecordingLocationAuthorization = .authorized
    var hasFullAccuracy = true
    private weak var delegateObject: AnyObject?

    var sourceDelegate: CLLocationManagerDelegate? {
        get { delegateObject as? CLLocationManagerDelegate }
        set { delegateObject = newValue }
    }

    func requestWhenInUseAuthorization() { /* no-op */ }
    func requestTemporaryFullAccuracy() { /* no-op */ }
    func startRecordingUpdates(profile: RecordingEnergyProfile) { /* no-op */ }
    func stopRecordingUpdates() { /* no-op */ }

    func deliver(_ location: CLLocation) {
        sourceDelegate?.locationManager?(
            CLLocationManager(),
            didUpdateLocations: [location]
        )
    }
}

@Suite("Observation cost")
struct ObservationCostTests {
    /// The sheet's top edge is written at frame rate while dragging, and the
    /// map repositions its location button from it — but nothing in SwiftUI
    /// should hear about it.
    @Test("dragging the sheet notifies only its own observer")
    func sheetMetricsAreIsolated() async {
        let metrics = SheetMetrics()
        let highlight = RouteHighlight()
        let sheetCounter = ObservationCounter { _ = metrics.topY }
        let highlightCounter = ObservationCounter { _ = highlight.coordinate }
        await sheetCounter.settle()

        for y in stride(from: 800.0, to: 400.0, by: -20) {
            metrics.topY = y
            await sheetCounter.settle()
        }
        #expect(sheetCounter.count == 20)
        #expect(highlightCounter.count == 0, "a sheet drag must not wake the route highlight's observer")
    }

    /// The map registers the two one-shot commands separately so that bumping
    /// one doesn't re-arm the other.
    @Test("the map's two commands notify independently")
    func mapCommandsAreIndependent() async {
        let controller = MapController()
        let fitCounter = ObservationCounter { _ = controller.fitRouteRequest }
        let regionCounter = ObservationCounter { _ = controller.showRegionRequest }
        await fitCounter.settle()

        controller.fitToRoute()
        await fitCounter.settle()
        #expect(fitCounter.count == 1)
        #expect(regionCounter.count == 0)

        controller.show(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        ))
        await regionCounter.settle()
        #expect(regionCounter.count == 1)
        #expect(fitCounter.count == 1, "showing a region must not also re-fit the route")
    }
}

@Suite("Route highlight")
struct RouteHighlightTests {
    private static let viewpoint = CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)

    /// The pin has to reach the map when it genuinely moves — the guard below
    /// is only worth having if this still holds.
    @Test("placing and moving the pin reaches the map")
    func movesArePublished() async {
        let highlight = RouteHighlight()
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        highlight.move(to: Self.viewpoint)
        await counter.settle()
        #expect(counter.count == 1)

        highlight.move(to: CLLocationCoordinate2D(latitude: 47.6400, longitude: 12.8600))
        await counter.settle()
        #expect(counter.count == 2)
        #expect(highlight.coordinate?.latitude == 47.64)
    }

    /// `CLLocationCoordinate2D` isn't `Equatable` (pinned by `an equal write to
    /// a coordinate notifies anyway`), so without the comparison in
    /// `move(to:)` this is a notification for a pin that hasn't moved.
    @Test("moving the pin where it already is doesn't wake the map")
    func repeatedPositionIsNotRepublished() async {
        let highlight = RouteHighlight()
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        highlight.move(to: Self.viewpoint)
        await counter.settle()
        #expect(counter.count == 1, "precondition: placing the pin reaches the map")

        highlight.move(to: CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600))
        await counter.settle()
        #expect(counter.count == 1, "same place — the map's annotation is already there")
        #expect(highlight.coordinate?.latitude == 47.63, "and the pin is still where it belongs")
    }

    @Test("clearing a placed pin reaches the map")
    func clearingIsPublished() async {
        let highlight = RouteHighlight()
        highlight.move(to: Self.viewpoint)
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        highlight.move(to: nil)
        await counter.settle()
        #expect(counter.count == 1)
        #expect(highlight.coordinate == nil)
    }

    /// `updateLiveFollow` hides the pin on every matched fix while auto-follow
    /// owns the map. Only the first of those has anything to say.
    @Test("auto-follow's per-second clear reaches the map once")
    func repeatedClearIsSilentAfterTheFirst() async {
        let highlight = RouteHighlight()
        highlight.move(to: Self.viewpoint)
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        for _ in 0..<5 {
            highlight.move(to: nil)
            await counter.settle()
        }
        #expect(counter.count == 1, "the pin is hidden once; the next four polls have nothing to say")
        #expect(highlight.coordinate == nil)
    }

    /// The hot path this type exists for. Scrubbing now interpolates continuously
    /// along route segments, so each distinct distance should move the pin, while
    /// repeated drag samples at the same distance must still be filtered before
    /// they re-register the map coordinator's observation through a `Task` hop.
    ///
    /// Settling between events on purpose: drag events arrive in separate
    /// runloop turns, so this counts them the way the map would see them
    /// rather than letting a synchronous burst coalesce into one.
    @Test("a drag moves the pin once per distinct interpolated position")
    func scrubbingWritesOncePerDistinctPosition() async throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let total = try #require(profile.distances.last)
        let highlight = RouteHighlight()
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        var dragEvents = 0
        var distinctPositions = 0
        for distance in stride(from: 0, through: total, by: 10) {
            let coordinate = profile.coordinate(atDistance: distance)
            highlight.move(to: coordinate)
            dragEvents += 1
            await counter.settle()
            highlight.move(to: coordinate)
            dragEvents += 1
            distinctPositions += 1
            await counter.settle()
        }

        #expect(dragEvents == distinctPositions * 2, "precondition: every position is submitted twice")
        #expect(
            counter.count == distinctPositions,
            "interpolated movement publishes, while repeating the same position remains silent"
        )
    }
}

@Suite("Location publishing")
struct LocationPublishingTests {
    private func location(
        horizontalAccuracy: CLLocationAccuracy,
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        timestamp: Date = .now
    ) -> CLLocation {
        CLLocation(
            coordinate: .init(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: timestamp
        )
    }

    @Test("reduced-accuracy fixes remain available for coarse features")
    func reducedAccuracyIsPublishedButNotRouteMatched() async {
        let manager = LocationManager()
        let approximate = location(horizontalAccuracy: 1500)

        manager.locationManager(CLLocationManager(), didUpdateLocations: [approximate])
        await Task.yield()

        #expect(manager.coordinate?.latitude == approximate.coordinate.latitude)
        #expect(manager.coordinate?.longitude == approximate.coordinate.longitude)
        #expect(
            manager.routeFix(
                maximumHorizontalAccuracy: RouteProfile.followMatchThresholdMeters
            ) == nil
        )
    }

    @Test("invalid and stale fixes are rejected")
    func invalidAndStaleFixesAreRejected() async {
        let staleManager = LocationManager()
        let stale = location(
            horizontalAccuracy: 10,
            timestamp: .now.addingTimeInterval(-(LocationFixPolicy.foregroundMaximumAge + 1))
        )
        staleManager.locationManager(CLLocationManager(), didUpdateLocations: [stale])
        await Task.yield()

        let invalidManager = LocationManager()
        let invalid = location(horizontalAccuracy: -1)
        invalidManager.locationManager(CLLocationManager(), didUpdateLocations: [invalid])
        await Task.yield()

        #expect(staleManager.coordinate == nil)
        #expect(invalidManager.coordinate == nil)
    }

    /// A fix's course is what tells auto-follow which leg of an out-and-back
    /// a walker is on, so what counts as a *usable* course decides whether
    /// that works at all — and both the foreground and the background feed
    /// ask this one question, so they can't drift apart.
    @Test("only a fix from someone actually moving carries a usable course")
    func courseNeedsMovement() {
        func fix(
            course: CLLocationDirection,
            courseAccuracy: CLLocationDirectionAccuracy,
            speed: CLLocationSpeed
        ) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: 47.63, longitude: 12.86),
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: -1,
                course: course,
                courseAccuracy: courseAccuracy,
                speed: speed,
                speedAccuracy: -1,
                timestamp: .now
            )
        }

        #expect(
            LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: 10, speed: 1.4)) == 180,
            "walking, and the receiver is sure which way"
        )

        // Standing at a viewpoint: the reported course wanders and means nothing.
        #expect(LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: 10, speed: 0)) == nil)
        // The receiver saying it doesn't know.
        #expect(LocationFixPolicy.course(of: fix(course: -1, courseAccuracy: -1, speed: 1.4)) == nil)
        // …or knowing so vaguely that it can't distinguish out from back.
        #expect(LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: 90, speed: 1.4)) == nil)
        // No uncertainty reported at all is absence of evidence, not evidence
        // of a bad course — simulated locations arrive exactly like this.
        #expect(LocationFixPolicy.course(of: fix(course: 180, courseAccuracy: -1, speed: 1.4)) == 180)
    }

    /// Position and course have to describe the same instant, or a walker
    /// gets matched against the way they were going somewhere else.
    @Test("a route fix carries the course of the fix it came from")
    func routeFixCarriesItsCourse() async throws {
        let manager = LocationManager()
        let walking = CLLocation(
            coordinate: .init(latitude: 47.63, longitude: 12.86),
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            course: 42,
            courseAccuracy: 5,
            speed: 1.4,
            speedAccuracy: -1,
            timestamp: .now
        )
        let tolerance = RouteProfile.followMatchThresholdMeters
        manager.locationManager(CLLocationManager(), didUpdateLocations: [walking])
        await settleDelegateHop(until: "the delivered fix to reach the manager") {
            manager.routeFix(maximumHorizontalAccuracy: tolerance) != nil
        }
        let fix = try #require(manager.routeFix(maximumHorizontalAccuracy: tolerance))
        #expect(fix.coordinate.latitude == 47.63)
        #expect(fix.course == 42)
    }

    /// CoreLocation can deliver far more often than once a second; the
    /// throttle is what keeps that off every observer downstream.
    ///
    /// Asserted on the published value rather than on a notification count.
    /// `ObservationCounter` re-arms through a `Task`, so ten writes in one
    /// runloop turn consume the single armed registration on the first and
    /// reach the counter exactly once whether the throttle exists or not —
    /// measured, by deleting `minimumPublishInterval` and watching this stay
    /// green. `coordinate` is the only witness that can tell the two apart:
    /// throttled it holds the *first* fix of the burst, unthrottled the last.
    @Test("a burst of fixes publishes once")
    func burstIsThrottled() {
        let clock = TestClock()
        let manager = LocationManager(clock: clock.read)

        for step in 0..<10 {
            manager.locationManager(
                CLLocationManager(),
                didUpdateLocations: [CLLocation(latitude: 47.63 + Double(step) * 1e-4, longitude: 12.86)]
            )
        }
        // `onMainActor` runs the delegate body synchronously here, so there is
        // a value to read without settling for one.
        #expect(manager.coordinate?.latitude == 47.63, "the nine behind the first are inside the window")

        // Past `minimumPublishInterval`, which is private; the sibling tests
        // step the same 1.1s over it.
        clock.advance(by: 1.1)
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.64, longitude: 12.86)]
        )
        #expect(manager.coordinate?.latitude == 47.64, "and the window reopens rather than latching shut")
    }

    /// A walker who has stopped — at a viewpoint, a hut, a photo — still gets
    /// a fix every second. Republishing each one as a new value would wake the
    /// map coordinator, which re-registers its observation through a `Task`
    /// hop, once a second for as long as the app is open.
    ///
    /// Nothing downstream needs that heartbeat: auto-follow and the weather
    /// poll both drive off `fixes`, which only emits when `coordinate`
    /// changes, and the map only uses it to center on the very first fix. So
    /// an unchanged fix has nobody to tell.
    @Test("an unchanged fix isn't republished")
    func unchangedFixIsNotRepublished() async {
        let clock = TestClock()
        let manager = LocationManager(clock: clock.read)
        let counter = ObservationCounter { _ = manager.coordinate }
        await counter.settle()

        let stationary = CLLocation(latitude: 47.6300, longitude: 12.8600)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [stationary])
        await counter.settle()
        #expect(counter.count == 1, "precondition: the first fix is published")

        // Past the 1 s throttle, so this one is not being dropped for timing —
        // it's the same place.
        clock.advance(by: 1.1)
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [
                CLLocation(latitude: stationary.coordinate.latitude, longitude: stationary.coordinate.longitude)
            ]
        )
        await counter.settle()
        #expect(counter.count == 1, "standing still should not wake the map's observation every second")
    }

    /// …while actually moving must still publish, or auto-follow stops.
    @Test("a fix that moved is published")
    func movedFixIsPublished() async {
        let clock = TestClock()
        let manager = LocationManager(clock: clock.read)
        let counter = ObservationCounter { _ = manager.coordinate }
        await counter.settle()

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6300, longitude: 12.8600)]
        )
        await counter.settle()
        clock.advance(by: 1.1)
        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 47.6305, longitude: 12.8600)]
        )
        await counter.settle()

        #expect(counter.count == 2)
        #expect(manager.coordinate?.latitude == 47.6305)
    }
}

@Suite("Download progress")
struct DownloadProgressTests {
    /// Progress still publishes once per saved tile, but only the focused
    /// download child views observe it; `HikeDetailView.body` observes
    /// low-frequency phase transitions instead.
    ///
    /// Saves are stubbed rather than pointed at a dead port: `completed` counts
    /// tiles *saved*, so a download where every tile fails now correctly
    /// publishes no progress at all, and there'd be nothing here to observe.
    @Test("progress notifies once per tile")
    func progressNotifiesPerTile() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            // Suspends before answering, so completions land in separate
            // runloop turns the way real fetches do — by yielding rather than
            // by sleeping, which would spend the same wall-clock time on every
            // run to buy the same ordering.
            saveTile: { _, _ in
                for _ in 0..<4 { await Task.yield() }
                return true
            }
        )
        let counter = ObservationCounter { _ = downloader.progress }
        await counter.settle()

        downloader.start(
            route: Fixture.ridgeRoute,
            source: ActiveTileSource(providerID: TileProvider.stadiaOutdoors.id, urlTemplate: "https://tiles.invalid/{z}/{x}/{y}.png", maximumZ: 14),
            claim: Fixture.unrecordedClaim
        )
        await downloader.waitForPlanning()
        let total = downloader.total
        #expect(total > 1, "precondition: there is more than one tile to fetch")

        await downloader.waitForCurrentRun()
        await counter.settle()

        #expect(downloader.completed == total)
        // Deliberately not `>= total`: this counter re-registers through a
        // `Task`, exactly like the map coordinator does, so completions that
        // land in the same runloop turn are coalesced — which is also what
        // SwiftUI does with the resulting invalidations. The point stands
        // either way: progress publishes repeatedly during a download, and
        // every view reading it is rebuilt each time.
        #expect(counter.count >= 2)
    }
}
