//
//  BackgroundTrackingProximityTests.swift
//  OpenHikesTests
//
//  The fourth arming condition: how far the phone is from the trail it would
//  be matching fixes against.
//
//  The other three — the toggle, the authorization and the selection — are
//  pinned by `BackgroundTrackingTests`, and every stub there answers the same
//  way wherever the device is. These are the tests that put the device
//  somewhere: a selection restored from a previous launch is a standing
//  registration, so "a trail selected in Berchtesgaden while the phone is in
//  Munich" is the steady state for anyone who has ever opened a trail and not
//  explicitly closed it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

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
    /// Held for the length of the test: the monitor references its delegate
    /// weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    /// Somewhere on ``Fixture/ridgeRoute``, which runs due north near
    /// Cupertino.
    private static let onTheTrail = CLLocationCoordinate2D(latitude: 37.3340, longitude: -122.0300)
    /// Reykjavík — far enough that no slack could reach, and deliberately not
    /// merely "a few towns over": the reported case was a continent away.
    private static let farAway = CLLocationCoordinate2D(latitude: 64.1466, longitude: -21.9426)

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
    /// go on: the selection, the trail's box, and where the phone last was.
    ///
    /// - Parameter position: `nil` writes no position at all, which is the
    ///   fresh-install case.
    @discardableResult private func seedPreviousLaunch(
        position: CLLocationCoordinate2D?,
        route: [RouteCoordinate] = Fixture.ridgeRoute,
        writesArea: Bool = true
    ) throws -> Hike {
        let hike = Fixture.hike(in: context, route: route)
        try context.save()
        defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
        if writesArea {
            let area = try #require(TrackedTrailArea(hikeID: hike.id, route: route))
            defaults.set(try JSONEncoder().encode(area), forKey: SettingsKey.trackedTrailArea)
        }
        if let position {
            defaults.set([position.latitude, position.longitude], forKey: SettingsKey.lastKnownCoordinate)
        }
        return hike
    }

    @discardableResult private func relaunch() -> BackgroundTrailTracker {
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    /// The reported bug. Tracking on, Always granted, a trail restored from
    /// the last session — and a phone nowhere near it. Before the proximity
    /// gate this launch armed monitoring, which then outlived the process and
    /// left the system's background-location indicator up after a force-quit.
    @Test("a launch far from the selected trail arms nothing")
    func launchFarFromTheTrailDoesNotArm() throws {
        try seedPreviousLaunch(position: Self.farAway)

        relaunch()

        #expect(monitor.startCount == 0, "every wake would return at the off-route branch")
        #expect(!monitor.isMonitoring)
    }

    /// The same launch, with the phone at the trailhead, is the launch the
    /// feed exists for and must be untouched.
    @Test("a launch near the selected trail arms monitoring")
    func launchNearTheTrailArms() throws {
        try seedPreviousLaunch(position: Self.onTheTrail)

        relaunch()

        #expect(monitor.startCount == 1)
        #expect(monitor.isMonitoring)
    }

    /// Nothing stored can prove the phone is anywhere, so the gate must not
    /// pretend it is far: a fresh install, or a hiker who has never granted
    /// When In Use, behaves exactly as it did before this condition existed.
    @Test("a launch with no stored position arms monitoring")
    func launchWithNoPositionArms() throws {
        try seedPreviousLaunch(position: nil)

        relaunch()

        #expect(monitor.startCount == 1, "absent is not far")
    }

    /// And neither can a box that has not been written yet — a selection made
    /// by a build that had no box to write.
    @Test("a launch with a position but no stored box arms monitoring")
    func launchWithNoBoxArms() throws {
        try seedPreviousLaunch(position: Self.farAway, writesArea: false)

        relaunch()

        #expect(monitor.startCount == 1)
    }

    /// A box belonging to a trail nobody is following answers the wrong
    /// question, so it is no answer at all.
    @Test("a box left over from another trail arms monitoring")
    func aStaleBoxArms() throws {
        let hike = try seedPreviousLaunch(position: Self.farAway)
        let strangerArea = try #require(TrackedTrailArea(hikeID: UUID(), route: hike.route))
        defaults.set(try JSONEncoder().encode(strangerArea), forKey: SettingsKey.trackedTrailArea)

        relaunch()

        #expect(monitor.startCount == 1)
    }

    /// A walk under way outranks the distance question outright: this is the
    /// feed that keeps a walk's coverage honest with the phone in a pocket,
    /// and the stored position can easily be the one from home.
    @Test("a walk under way arms monitoring at any distance")
    func aWalkArmsRegardlessOfDistance() throws {
        let hike = try seedPreviousLaunch(position: Self.farAway)
        let tracker = relaunch()
        #expect(monitor.startCount == 0, "precondition: the distance gate is holding it down")

        tracker.walkDidStart(hikeID: hike.id)

        #expect(monitor.startCount == 1)
        #expect(monitor.isMonitoring)
    }

    /// The re-arm half. Once monitoring is down there is no significant-change
    /// delivery of its own left to notice the hiker arriving, so the decision
    /// is re-taken from the foreground feed's coordinate — which is what the
    /// hiker provides by opening the app at the trailhead.
    @Test("a position near the trail re-arms a launch that stood down")
    func arrivingAtTheTrailReArms() throws {
        try seedPreviousLaunch(position: Self.farAway)
        let tracker = relaunch()
        #expect(monitor.startCount == 0, "precondition")

        tracker.deviceDidMove(to: Self.onTheTrail)

        #expect(monitor.startCount == 1)
    }

    /// `nil` is the feed's answer before its first delivery, and it means *no
    /// news*. Read as *nowhere* it would forget the position that stood
    /// monitoring down, and every foreground would re-arm the trail the hiker
    /// left selected months ago.
    @Test("a movement with no coordinate leaves the decision alone")
    func noCoordinateChangesNothing() throws {
        try seedPreviousLaunch(position: Self.farAway)
        let tracker = relaunch()

        tracker.deviceDidMove(to: nil)

        #expect(monitor.startCount == 0)
    }

    /// The other direction, and the one that closes the reported symptom for
    /// a process that is *already* armed: the wake that proves the phone is
    /// far away is the last one it buys.
    @Test("a fix far from the trail stands monitoring down")
    func aFixFarAwayStandsDown() throws {
        try seedPreviousLaunch(position: Self.onTheTrail)
        relaunch()
        #expect(monitor.isMonitoring, "precondition: armed at the trailhead")

        monitor.deliver(
            CLLocation(
                coordinate: Self.farAway,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: -1,
                course: -1,
                speed: -1,
                timestamp: .now
            )
        )

        #expect(!monitor.isMonitoring)
        #expect(monitor.stopCount >= 1)
    }

    /// Selecting a trail writes its box, so the *next* launch can take the
    /// distance decision at all. Written off the main actor along with the
    /// widget snapshot, which is why this waits for that publication.
    @Test("selecting a trail records the box a later launch reads")
    func selectingRecordsTheBox() async throws {
        let hike = Fixture.hike(in: context, route: Fixture.ridgeRoute)
        try context.save()
        let tracker = relaunch()

        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        let data = try #require(defaults.data(forKey: SettingsKey.trackedTrailArea))
        let stored = try JSONDecoder().decode(TrackedTrailArea.self, from: data)
        #expect(stored.hikeID == hike.id)
        #expect(stored.box.contains(Self.onTheTrail))
        #expect(!stored.box.contains(Self.farAway))
    }

    /// And deselecting takes it away with the selection, so nothing can
    /// answer the distance question about a trail nobody is following.
    @Test("deselecting clears the stored box")
    func deselectingClearsTheBox() throws {
        try seedPreviousLaunch(position: Self.onTheTrail)
        let tracker = relaunch()

        tracker.hikeSelectionChanged(to: nil)

        #expect(defaults.data(forKey: SettingsKey.trackedTrailArea) == nil)
    }
}
}
