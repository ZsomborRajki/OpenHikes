//
//  BackgroundTrackingProximityTests.swift
//  OpenHikesTests
//
//  The fourth arming condition: whether the phone is anywhere near the trail
//  it would be matching fixes against.
//
//  The other three — the toggle, the authorization and the selection — are
//  pinned by `BackgroundTrackingTests`, and every stub there answers the same
//  way wherever the device is. These are the tests that put the device
//  somewhere: a selection restored from a previous launch is a standing
//  registration, so "a trail selected in Berchtesgaden while the phone is in
//  Munich" is the steady state for anyone who has ever opened a trail and not
//  explicitly closed it.
//
//  What "somewhere" means here is not a coordinate. The app never holds one
//  for this purpose — it registers a region and asks the system. So the fake
//  below answers as the system does, in the three states a condition can be
//  in, and a test puts the phone near or far by saying which.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

/// The system's side of the region gate.
///
/// An actor because the protocol is `Sendable` and the real one is too: the
/// tracker reaches it with `await` from the main actor, exactly as it reaches
/// `CLMonitor`.
actor FakeTrailRegionMonitor: TrailRegionMonitor {
    private(set) var registeredRegion: TrailRegion?
    private(set) var setRegionCount = 0
    private(set) var observerCount = 0
    private var state: TrailRegionState
    private var onChange: (@MainActor @Sendable (TrailRegionState) -> Void)?

    /// - Parameter state: what a launch finds the system already saying,
    ///   which is the answer a *previous* process's registration accrued.
    init(state: TrailRegionState = .unknown) {
        self.state = state
    }

    func setRegion(_ region: TrailRegion?) {
        registeredRegion = region
        setRegionCount += 1
        // As CoreLocation does: a freshly added condition starts unknown
        // whatever was said about the one it replaced.
        state = .unknown
    }

    func currentState() -> TrailRegionState { state }

    func startObserving(_ onChange: @escaping @MainActor @Sendable (TrailRegionState) -> Void) {
        self.onChange = onChange
        observerCount += 1
    }

    /// Delivers a crossing, as the system would.
    ///
    /// Awaiting the main-actor hop is what makes this deterministic: when it
    /// returns, the tracker has taken the arming decision this state changes.
    func deliver(_ next: TrailRegionState) async {
        state = next
        await onChange?(next)
    }
}

// Nested in the widget-feed group for one test's sake: selecting a trail
// publishes the App Group snapshot, and that file is shared with the suites
// there. The arming tests themselves touch nothing outside their own defaults.
extension WidgetFeedSuites {
@Suite("Background tracking proximity", .serialized)
final class BackgroundTrackingProximityTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    // periphery:ignore - assigned and never read on purpose; it is the strong
    // reference that keeps the tracker alive.
    /// Held for the length of the test: the monitor references its delegate
    /// weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// A previous launch's leftovers, which is all a relaunched process has to
    /// go on: the selection, and a condition registered by a process that is
    /// no longer running.
    @discardableResult private func seedPreviousLaunch(
        route: [RouteCoordinate] = Fixture.ridgeRoute
    ) throws -> Hike {
        let hike = Fixture.hike(in: context, route: route)
        try context.save()
        defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
        return hike
    }

    /// A launch that finds the system already saying `state`.
    private func relaunch(
        saying state: TrailRegionState
    ) async -> (tracker: BackgroundTrailTracker, region: FakeTrailRegionMonitor) {
        let region = FakeTrailRegionMonitor(state: state)
        let newTracker = BackgroundTrailTracker(
            container: container,
            monitor: monitor,
            regionMonitor: region,
            defaults: defaults
        )
        retainedTracker = newTracker
        await newTracker.waitForTrailRegionWatch()
        return (newTracker, region)
    }

    /// The reported bug. Tracking on, Always granted, a trail restored from
    /// the last session — and a phone nowhere near it. Before the proximity
    /// gate this launch armed monitoring, which then outlived the process and
    /// left the system's background-location indicator up after a force-quit.
    @Test("a launch outside the trail's region stands monitoring down")
    func launchOutsideTheRegionStandsDown() async throws {
        try seedPreviousLaunch()

        _ = await relaunch(saying: .outside)

        // The end state, not the call count: the launch arms before the
        // system has answered — see `launchIsArmedBeforeTheAnswerLands` — and
        // what matters is that it does not stay that way. Every wake it would
        // otherwise buy returns at the off-route branch.
        #expect(!monitor.isMonitoring)
        #expect(monitor.stopCount >= 1, "the registration a previous launch left is cancelled here")
    }

    /// The same launch, with the phone at the trailhead, is the launch the
    /// feed exists for and must be untouched.
    @Test("a launch inside the trail's region arms monitoring")
    func launchInsideTheRegionArms() async throws {
        try seedPreviousLaunch()

        _ = await relaunch(saying: .inside)

        #expect(monitor.startCount >= 1)
        #expect(monitor.isMonitoring)
    }

    /// Unknown is what a condition the system has not evaluated says, and what
    /// it says when there is no condition at all — a fresh install, a trail
    /// too large to fence, a hiker who has never granted Always. None of them
    /// can prove the phone is far away, so all of them arm, exactly as they
    /// did before this condition existed.
    @Test("a launch the system has no answer for arms monitoring")
    func launchWithNoAnswerArms() async throws {
        try seedPreviousLaunch()

        _ = await relaunch(saying: .unknown)

        #expect(monitor.startCount >= 1, "unknown is not far")
    }

    /// The arming decision is taken before the system has been asked — a
    /// `CLMonitor` is opened with an await, and a launch started to hand over
    /// one fix cannot wait on it. Armed is the answer that has to hold there.
    @Test("a launch is armed before the system has answered")
    func launchIsArmedBeforeTheAnswerLands() throws {
        try seedPreviousLaunch()

        let tracker = BackgroundTrailTracker(
            container: container,
            monitor: monitor,
            regionMonitor: FakeTrailRegionMonitor(state: .outside),
            defaults: defaults
        )
        retainedTracker = tracker

        #expect(monitor.isMonitoring, "fail open until the system says otherwise")
    }

    /// A walk under way outranks the region question outright: this is the
    /// feed that keeps a walk's coverage honest with the phone in a pocket,
    /// and the registered condition can easily be another trail's.
    @Test("a walk under way arms monitoring wherever the phone is")
    func aWalkArmsRegardlessOfRegion() async throws {
        let hike = try seedPreviousLaunch()
        let (tracker, _) = await relaunch(saying: .outside)
        #expect(!monitor.isMonitoring, "precondition: the region gate is holding it down")
        let armsBefore = monitor.startCount

        tracker.walkDidStart(hikeID: hike.id)

        #expect(monitor.startCount == armsBefore + 1)
        #expect(monitor.isMonitoring)
    }

    /// The re-arm half, and the one the stored-position draft of this gate
    /// could not do on its own: once monitoring is down there is no feed of
    /// the tracker's left to notice the hiker arriving. The system has one,
    /// and it delivers the crossing whether or not this app is running.
    @Test("crossing into the region re-arms a launch that stood down")
    func arrivingAtTheTrailReArms() async throws {
        try seedPreviousLaunch()
        let (_, region) = await relaunch(saying: .outside)
        #expect(!monitor.isMonitoring, "precondition")
        let armsBefore = monitor.startCount

        await region.deliver(.inside)

        #expect(monitor.startCount == armsBefore + 1)
        #expect(monitor.isMonitoring)
    }

    /// The other direction, and the one that closes the reported symptom for
    /// a process that is *already* armed: leaving is the last thing the
    /// registration buys.
    @Test("crossing out of the region stands monitoring down")
    func leavingTheRegionStandsDown() async throws {
        try seedPreviousLaunch()
        let (_, region) = await relaunch(saying: .inside)
        #expect(monitor.isMonitoring, "precondition: armed at the trailhead")

        await region.deliver(.outside)

        #expect(!monitor.isMonitoring)
        #expect(monitor.stopCount >= 1)
    }

    /// A launch has to consume the event stream, not just read the record:
    /// the crossing that relaunched the process is delivered through it, and
    /// CoreLocation stops monitoring conditions whose events nothing is
    /// configured to receive.
    @Test("a launch starts observing the system's events")
    func launchObservesEvents() async throws {
        try seedPreviousLaunch()

        let (_, region) = await relaunch(saying: .outside)

        #expect(await region.observerCount == 1)
    }

    /// Selecting a trail registers its region, so the *next* launch has
    /// something to ask the system about. Computed off the main actor along
    /// with the widget snapshot, which is why this waits for that publication.
    @Test("selecting a trail registers the region a later launch asks about")
    func selectingRegistersTheRegion() async throws {
        let hike = Fixture.hike(in: context, route: Fixture.ridgeRoute)
        try context.save()
        let (tracker, region) = await relaunch(saying: .unknown)

        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let registered = try #require(await region.registeredRegion)
        let onTheTrail = try #require(Fixture.ridgeRoute.first).clCoordinate
        let separation = CLLocation(latitude: registered.latitude, longitude: registered.longitude)
            .distance(from: CLLocation(latitude: onTheTrail.latitude, longitude: onTheTrail.longitude))
        #expect(separation <= registered.radiusMeters)
    }

    /// And deselecting takes it away with the selection, so nothing is left
    /// registered for a trail nobody is following. That leftover registration
    /// is the whole of what this issue is about.
    @Test("deselecting removes the registered region")
    func deselectingRemovesTheRegion() async throws {
        try seedPreviousLaunch()
        let (tracker, region) = await relaunch(saying: .inside)

        tracker.hikeSelectionChanged(to: nil)
        await tracker.waitForSelectionPublish()

        #expect(await region.registeredRegion == nil)
        #expect(await region.setRegionCount >= 1, "removed, not merely never set")
        #expect(!monitor.isMonitoring)
    }
}
}
