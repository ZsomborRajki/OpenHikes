//
//  BackgroundDeliveryTests.swift
//  OpenHikesTests
//
//  "Background delivery", split out of BackgroundTrackingTests.swift so that
//  a file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import SwiftData
import Testing

extension WidgetFeedSuites {
/// These write the App Group payload, so they share the file the other two
/// feed suites use and are serialized alongside them.
@Suite("Background delivery", .serialized)
final class BackgroundDeliveryTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    /// Held for the length of the test: the monitor references its delegate
    /// weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// A hike stored in the container and recorded as the last selection —
    /// which is all a relaunched process has to go on.
    private func selectedHike(route: [RouteCoordinate] = Fixture.ridgeRoute) -> Hike {
        let hike = Fixture.hike(in: context, route: route)
        try? context.save()
        defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
        return hike
    }

    /// A tracker built the way a background relaunch builds one: no selection
    /// call, no published snapshot, nothing but what's on disk.
    @discardableResult private func relaunchedTracker() -> BackgroundTrailTracker {
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    private func fix(
        at coordinate: CLLocationCoordinate2D,
        accuracy: CLLocationAccuracy = 10,
        age: TimeInterval = 0
    ) -> CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: Date().addingTimeInterval(-age)
        )
    }

    /// Hands a fix to the delegate and waits for the publication it starts.
    ///
    /// Matching a fix against a route and writing the App Group snapshot both
    /// happen off the main actor, so reading the store straight after the
    /// delivery would read it before anything had been written. This is the
    /// tracker's own seam rather than a settle: it waits for exactly the work
    /// this fix started, not for the machine to look quiet. On a fix the
    /// tracker refuses outright — stale, imprecise, or for a hike that is gone
    /// — nothing was started and the wait returns at once, which is what makes
    /// it safe to use for the negative assertions too.
    private func deliver(_ location: CLLocation) async {
        monitor.deliver(location)
        await retainedTracker?.waitForLiveFixPublish()
    }

    /// A walk left open by the last launch outranks the last selection: the
    /// relaunched process restores the walk, pins the tracker to its hike,
    /// and a significant-change fix extends its coverage — the feed that
    /// keeps a walk honest with the phone in a pocket.
    @Test("a fix delivered after a relaunch extends the walk left open, not the selection")
    func backgroundFixExtendsTheOpenWalk() async throws {
        let walked = Fixture.hike(in: context, title: "Walked", route: Fixture.ridgeRoute)
        let profile = RouteProfile(route: walked.route)
        var record = TrailWalkRecord(
            hikeID: walked.id,
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: .now
        )
        record.coverage.record(distance: profile.distances[0])
        record.coverage.record(distance: profile.distances[1])
        walked.walkInProgress = record
        try context.save()
        // The selection moved on to another trail before the kill.
        let compared = selectedHike(route: Fixture.loopRoute)
        let tracker = relaunchedTracker()
        let session = TrailWalkSession(context: context, tracker: tracker)
        session.restoreAtLaunch()
        #expect(tracker.trackedHikeID == walked.id, "the walk's hike, not \(compared.title)")
        let before = session.coveredFraction

        await deliver(fix(at: profile.coordinates[2]))

        #expect(session.coveredFraction > before)
        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.hikeID == walked.id)
        #expect(snapshot.walk?.coveredFraction == session.coveredFraction)
    }

    /// Abandonment used to be checked only inside the matched branch. Once
    /// the hiker left the trail every significant change was unmatched, so
    /// nothing reached the session and the six-hour rule never fired while
    /// the app stayed backgrounded — the widget and the Lock Screen kept an
    /// off-trail walk indefinitely, until the app came back to the foreground.
    @Test("an off-route background fix still closes a walk abandoned six hours ago")
    func offRouteBackgroundFixClosesAnAbandonedWalk() async throws {
        let walked = Fixture.hike(in: context, title: "Walked", route: Fixture.ridgeRoute)
        let profile = RouteProfile(route: walked.route)
        var record = TrailWalkRecord(
            hikeID: walked.id,
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: Date(timeIntervalSinceNow: -TrailWalkPolicy.abandonAfter - 7200)
        )
        record.coverage.record(distance: profile.distances[0])
        record.coverage.record(distance: profile.distances[1])
        record.lastMatchedAt = Date(timeIntervalSinceNow: -TrailWalkPolicy.abandonAfter - 60)
        walked.walkInProgress = record
        try context.save()
        defaults.set(walked.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
        let tracker = relaunchedTracker()
        let session = TrailWalkSession(context: context, tracker: tracker)
        session.restoreAtLaunch()
        #expect(session.walkedHikeID == walked.id, "precondition: adopted, since it is not stale enough to close")

        // ~900 m west of the ridge: accepted, and matched against nothing.
        await deliver(fix(at: CLLocationCoordinate2D(latitude: 37.3340, longitude: -122.0400)))

        #expect(session.walkedHikeID == nil, "an unmatched fix is still a fix the rule can be asked about")
        #expect(walked.walkInProgress == nil)
    }

    /// The whole feature in one test: woken with no in-memory state, the app
    /// matches the fix against the hike `UserDefaults` says was selected and
    /// publishes progress along it.
    @Test("a fix delivered after a relaunch is matched against the persisted selection")
    func backgroundFixPublishesProgress() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        await deliver(fix(at: profile.coordinates[3]))

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.hikeID == hike.id, "the selection came from defaults, not from memory")
        let live = try #require(snapshot.liveFix)
        #expect(live.distanceAlongRouteMeters.isApproximatelyEqual(to: profile.distances[3], absoluteTolerance: 1))
    }

    /// Off the trail, the widget shows the trail's length rather than a
    /// position that isn't on it.
    @Test("a fix off the trail clears the published position")
    func offRouteFixClearsTheLiveFix() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        await deliver(fix(at: profile.coordinates[2]))
        #expect(try #require(SharedStore.load()).liveFix != nil, "precondition: on the trail first")

        // ~900 m west of the ridge, well past the follow threshold.
        await deliver(fix(at: CLLocationCoordinate2D(latitude: 37.3340, longitude: -122.0400)))

        let snapshot = try #require(SharedStore.load())
        #expect(snapshot.liveFix == nil, "a hiker who left the trail has no progress along it")
        #expect(snapshot.hikeID == hike.id, "but the trail itself is still what's shown")
    }

    /// Significant-change delivery hands over cached fixes on relaunch, and a
    /// fix older than ``LocationFixPolicy/backgroundMaximumAge`` is a position
    /// the hiker has left.
    @Test("a stale fix is refused")
    func staleFixIsRefused() async {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        await deliver(fix(at: profile.coordinates[3], age: LocationFixPolicy.backgroundMaximumAge + 60))

        #expect(SharedStore.load() == nil, "nothing should have been published at all")
    }

    /// A fix whose uncertainty is wider than the matching tolerance can't say
    /// which part of a trail someone is on — including whether they're on it.
    @Test("a fix too imprecise to match is refused")
    func impreciseFixIsRefused() async {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        await deliver(
            fix(at: profile.coordinates[3], accuracy: RouteProfile.followMatchThresholdMeters + 100)
        )

        #expect(SharedStore.load() == nil)
    }

    /// The hike was deleted while the app was suspended, and the wake-up
    /// arrives for a selection that no longer exists.
    @Test("a fix for a hike that has been deleted publishes nothing")
    func deletedHikePublishesNothing() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()
        context.delete(hike)
        try context.save()

        await deliver(fix(at: profile.coordinates[3]))

        #expect(SharedStore.load() == nil, "there is no trail to report progress along")
    }

    /// With nothing recorded as selected there is nothing to match against,
    /// which is what a wake-up before the user has ever picked a trail looks
    /// like.
    @Test("a fix with no persisted selection publishes nothing")
    func noSelectionPublishesNothing() async {
        _ = Fixture.hike(in: context)
        relaunchedTracker()

        await deliver(fix(at: Fixture.ridgeRoute[3].clCoordinate))

        #expect(SharedStore.load() == nil)
    }

    /// The continuity reference `RouteProfile.nearestPoint` needs is persisted
    /// precisely because a relaunch has no memory: on a loop, the fix alone is
    /// ambiguous, and "where were they last time?" is what resolves it.
    @Test("matching continues from the distance the previous launch persisted")
    func matchingResumesFromPersistedDistance() async throws {
        // An out-and-back: at the trailhead the outbound and return legs are
        // less than a metre apart, so the fix alone cannot say which of them
        // the hiker is on. Only the persisted distance can.
        let hike = selectedHike(route: Fixture.outAndBackRoute)
        let profile = RouteProfile(route: hike.route)
        let total = try #require(profile.distances.last)
        relaunchedTracker()

        let trailhead = profile.coordinates[0]
        await deliver(fix(at: trailhead))
        let cold = try #require(SharedStore.load()?.liveFix)
        #expect(cold.distanceAlongRouteMeters < total / 2, "with nothing to go on, a fix here is the start")

        // Now the app is relaunched knowing the hiker was nearly home. The
        // wait above is what makes this safe to write here: matching reads the
        // reference off the main actor now, so seeding it while the previous
        // fix was still in flight would decide nothing.
        defaults.set(total, forKey: SettingsKey.lastMatchedDistance)
        await deliver(fix(at: trailhead))

        let resumed = try #require(SharedStore.load()?.liveFix)
        #expect(
            resumed.distanceAlongRouteMeters > total / 2,
            "a hiker finishing an out-and-back must not be reported as just starting it"
        )
    }

    /// And it writes one back, so the *next* wake-up has the same continuity.
    @Test("a matched background fix persists its distance for the next launch")
    func matchedFixPersistsItsDistance() async throws {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        relaunchedTracker()

        await deliver(fix(at: profile.coordinates[3]))

        let persisted = defaults.object(forKey: SettingsKey.lastMatchedDistance) as? Double
        #expect((try #require(persisted)).isApproximatelyEqual(to: profile.distances[3], absoluteTolerance: 1))
    }

    // MARK: The boundary an End leaves behind

    /// Walks `hike` far enough to be worth keeping and then taps End, which
    /// arms the boundary the next two tests are about.
    private func endedWalk(on hike: Hike, profile: RouteProfile, session: TrailWalkSession) {
        for index in 0...2 {
            session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[index])
        }
        session.end()
    }

    /// The reported bug. Ending a walk holds the trail closed until the
    /// hiker leaves its route, and leaving used to be reported only by the
    /// detail view's own matcher — so a hiker who tapped End, locked the
    /// phone, walked away and came back found the leave had happened where
    /// nothing was looking. The first foreground match on their return was
    /// still refused, and no second walk could start until another foreground
    /// off-route fix or a trip through the Auto-Follow toggle.
    @Test("an off-route background fix rearms a hike whose walk was ended")
    func offRouteBackgroundFixRearmsAnEndedWalk() async {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        let tracker = relaunchedTracker()
        let session = TrailWalkSession(context: context, tracker: tracker)
        endedWalk(on: hike, profile: profile, session: session)
        #expect(!session.canStart(hike), "precondition: End holds the trail closed")

        // The walk away from the trail, seen only by the background feed:
        // ~900 m west of the ridge, well past the follow threshold.
        await deliver(fix(at: CLLocationCoordinate2D(latitude: 37.3340, longitude: -122.0400)))

        // Back on the trail, and the detail view opened again: the first
        // foreground match is the one that used to be refused.
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.walkedHikeID == hike.id, "coming back to the trail is a walk of its own")
    }

    /// …but only for a fix that actually reached the route. A stale or
    /// imprecise one is refused before matching and says nothing about where
    /// the hiker is relative to the trail — including whether they left it —
    /// so it must not spend the boundary an End is holding.
    @Test("a rejected background fix leaves the boundary standing")
    func rejectedBackgroundFixDoesNotRearm() async {
        let hike = selectedHike()
        let profile = RouteProfile(route: hike.route)
        let tracker = relaunchedTracker()
        let session = TrailWalkSession(context: context, tracker: tracker)
        endedWalk(on: hike, profile: profile, session: session)

        // The same place off the ridge, reported twice in ways the fix policy
        // refuses before matching ever runs.
        let offTheRidge = CLLocationCoordinate2D(latitude: 37.3340, longitude: -122.0400)
        await deliver(fix(at: offTheRidge, age: LocationFixPolicy.backgroundMaximumAge + 60))
        #expect(!session.canStart(hike), "a cached fix from before the End proves nothing")

        await deliver(fix(at: offTheRidge, accuracy: RouteProfile.followMatchThresholdMeters + 100))
        #expect(!session.canStart(hike), "nor does one that cannot say which side of the trail it is on")

        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        #expect(session.walkedHikeID == nil, "so End still stands, and no second walk starts")
    }
}
}
