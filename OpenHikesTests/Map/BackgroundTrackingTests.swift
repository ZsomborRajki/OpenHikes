//
//  BackgroundTrackingTests.swift
//  OpenHikesTests
//
//  The background-relaunch path: the app is woken by a significant location
//  change with no in-memory state at all, and everything it then does is
//  decided by three things it reads from outside itself — whether Always
//  authorization is granted, which hike `UserDefaults` says was selected, and
//  a fix delivered through a `CLLocationManagerDelegate` callback.
//
//  All three are now injected (`SignificantLocationMonitor`, a `UserDefaults`
//  suite, a clock), which is what makes any of this reachable from a test.
//  Before that, the only way to exercise a relaunch was to go for a walk.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

/// Stands in for the app's second `CLLocationManager` — the significant-change
/// one. Records what the tracker asked it to do, and answers the two
/// authorization questions however the test says.
final class StubLocationMonitor: SignificantLocationMonitor {
    enum Authorization {
        case notDetermined, whenInUse, always, denied
    }

    var authorization: Authorization = .notDetermined
    private(set) var isMonitoring = false
    private(set) var alwaysAccessRequests = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    weak var monitorDelegateObject: AnyObject?

    var isAlwaysAuthorized: Bool { authorization == .always }

    var canRequestAlwaysAccess: Bool {
        authorization == .notDetermined || authorization == .whenInUse
    }

    var monitorDelegate: CLLocationManagerDelegate? {
        get { monitorDelegateObject as? CLLocationManagerDelegate }
        set { monitorDelegateObject = newValue }
    }

    func requestAlwaysAccess() { alwaysAccessRequests += 1 }

    func startSignificantLocationUpdates() {
        isMonitoring = true
        startCount += 1
    }

    func stopSignificantLocationUpdates() {
        isMonitoring = false
        stopCount += 1
    }

    /// Delivers a fix exactly as CoreLocation does — through the delegate the
    /// tracker registered, not by calling into it directly.
    ///
    /// The tracker's `nonisolated` callbacks reach main-actor state through
    /// `onMainActor`, which runs the body synchronously when the caller is
    /// already on the main actor — and a main-actor-isolated test always is.
    /// So the tracker has *started* handling the fix by the time this returns,
    /// and anything it decides synchronously (whether the fix is accepted at
    /// all, which hike it belongs to) is already settled. Matching it against
    /// the route and writing the App Group snapshot are not: both were moved
    /// off the main actor, so a test asserting on the store waits through
    /// ``BackgroundDeliveryTests/deliver(_:)``.
    func deliver(_ location: CLLocation) {
        monitorDelegate?.locationManager?(CLLocationManager(), didUpdateLocations: [location])
    }

    /// The user answering the Always prompt, long after it was shown.
    /// Synchronous: nothing about arming monitoring leaves the main actor.
    func grantAlways() {
        authorization = .always
        monitorDelegate?.locationManagerDidChangeAuthorization?(CLLocationManager())
    }
}

/// A `UserDefaults` nobody else in the process is reading, so a test can seed
/// a "previous launch" without editing the host app's own settings.
func makeScratchDefaults() throws -> UserDefaults {
    let suite = "OpenHikesTests.\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suite))
}

// MARK: - Authorization

/// No App Group needed: none of these publish anything. They're about which
/// CoreLocation calls the tracker makes, and when.
@Suite("Background tracking authorization")
final class BackgroundTrackingAuthorizationTests {
    private let container: ModelContainer
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    // periphery:ignore - assigned and never read on purpose; it is the strong
    // reference that keeps the tracker alive.
    /// Held for the length of the test: the monitor references its delegate
    /// weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        defaults = try makeScratchDefaults()
    }

    @discardableResult private func makeTracker() -> BackgroundTrailTracker {
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    /// Records a selection the way a previous launch would have left one.
    ///
    /// Monitoring is armed only when there is a trail to match fixes against,
    /// and these tests are about the other two conditions — so the id is all
    /// they need, and it never has to name a hike that exists.
    private func seedSelection() {
        defaults.set(UUID().uuidString, forKey: SettingsKey.lastSelectedHikeID)
    }

    @Test("turning tracking on with Always already granted starts monitoring")
    func enablingWhenAuthorizedStarts() {
        monitor.authorization = .always
        seedSelection()
        let tracker = makeTracker()

        tracker.setEnabled(true)

        #expect(monitor.isMonitoring)
        #expect(monitor.alwaysAccessRequests == 0, "there is nothing left to ask for")
    }

    /// The common path: the app already has When In Use for the map, and
    /// Always is a second prompt the user answers outside the app.
    @Test("turning tracking on without Always asks for it rather than starting")
    func enablingWithoutAlwaysAsks() {
        for authorization in [StubLocationMonitor.Authorization.notDetermined, .whenInUse] {
            let localMonitor = StubLocationMonitor()
            localMonitor.authorization = authorization
            let localTracker = BackgroundTrailTracker(container: container, monitor: localMonitor, defaults: defaults)
            retainedTracker = localTracker

            localTracker.setEnabled(true)

            // Nothing is selected here, and the prompt still goes up: the
            // toggle is a standing preference, and answering it is a trip out
            // of the app the user shouldn't repeat when they pick a trail.
            #expect(localMonitor.alwaysAccessRequests == 1, "\(authorization)")
            #expect(!localMonitor.isMonitoring, "monitoring without Always would never deliver anything")
        }
    }

    /// A refusal is an answer. Re-prompting can't change it — only Settings
    /// can — so the toggle must not keep asking.
    @Test("a refused app asks for nothing and starts nothing")
    func deniedAuthorizationDoesNothing() {
        monitor.authorization = .denied
        let tracker = makeTracker()

        tracker.setEnabled(true)

        #expect(monitor.alwaysAccessRequests == 0)
        #expect(!monitor.isMonitoring)
    }

    @Test("turning tracking off stops monitoring")
    func disablingStops() {
        monitor.authorization = .always
        seedSelection()
        let tracker = makeTracker()
        tracker.setEnabled(true)
        // Not zero: the launch above found the toggle off and stood monitoring
        // down, which is how a registration left over from a previous launch
        // is cancelled. This test is about the *next* stop.
        let stopsBeforeDisabling = monitor.stopCount

        tracker.setEnabled(false)

        #expect(!monitor.isMonitoring)
        #expect(monitor.stopCount == stopsBeforeDisabling + 1)
    }

    /// The grant arrives minutes later, from a system prompt shown after the
    /// user has left the app. Nothing else will start monitoring for them.
    @Test("granting Always afterwards arms monitoring")
    func grantingAlwaysLaterStarts() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        seedSelection()
        let tracker = makeTracker()
        tracker.setEnabled(true)
        #expect(!monitor.isMonitoring, "precondition: the prompt is still open")

        monitor.grantAlways()

        #expect(monitor.isMonitoring)
    }

    /// …but only if the feature is actually on. Always may be granted for
    /// reasons of its own, and an authorization callback is not consent to
    /// start spending battery.
    @Test("granting Always with the feature off starts nothing")
    func grantingAlwaysWhileDisabledStartsNothing() {
        defaults.set(false, forKey: SettingsKey.backgroundTrackingEnabled)
        makeTracker()

        monitor.grantAlways()

        #expect(!monitor.isMonitoring)
    }

    /// Monitoring doesn't survive a process launch: the system wakes the app
    /// *so that* it can re-register and receive the pending event. An app that
    /// doesn't re-arm here simply stops updating, silently, forever.
    @Test("a launch with tracking on and Always granted re-arms monitoring")
    func launchReArmsMonitoring() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always
        seedSelection()

        makeTracker()

        #expect(monitor.isMonitoring, "the wake-up is wasted otherwise")
    }

    @Test("a launch with tracking off re-arms nothing")
    func launchWithoutTrackingDoesNotArm() {
        monitor.authorization = .always
        seedSelection()
        makeTracker()
        #expect(!monitor.isMonitoring)
    }

    /// The toggle and the grant are not enough on their own. Armed with
    /// nothing selected, every significant change relaunches the app only to
    /// find no hike to match against — which over a long drive is hundreds of
    /// wasted wakes, and the iOS background-location reminder that follows
    /// them.
    @Test("a launch with tracking on but nothing selected arms nothing")
    func launchWithoutSelectionDoesNotArm() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always

        makeTracker()

        #expect(monitor.startCount == 0, "there is no trail to match a fix against")
    }

    /// …and the grant arriving later doesn't change that.
    @Test("granting Always with nothing selected starts nothing")
    func grantingAlwaysWithoutSelectionStartsNothing() {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        makeTracker()

        monitor.grantAlways()

        #expect(monitor.startCount == 0)
    }
}

// MARK: - Delivery

extension WidgetFeedSuites {
/// These write the App Group payload, so they share the file the other two
/// feed suites use and are serialized alongside them.
@Suite("Background delivery", .serialized)
final class BackgroundDeliveryTests {
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
    /// the walker left the trail every significant change was unmatched, so
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
        #expect(abs(live.distanceAlongRouteMeters - profile.distances[3]) < 1)
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
        #expect(snapshot.liveFix == nil, "a walker who left the trail has no progress along it")
        #expect(snapshot.hikeID == hike.id, "but the trail itself is still what's shown")
    }

    /// Significant-change delivery hands over cached fixes on relaunch, and a
    /// fix older than ``LocationFixPolicy/backgroundMaximumAge`` is a position
    /// the walker has left.
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
        // the walker is on. Only the persisted distance can.
        let hike = selectedHike(route: Fixture.outAndBackRoute)
        let profile = RouteProfile(route: hike.route)
        let total = try #require(profile.distances.last)
        relaunchedTracker()

        let trailhead = profile.coordinates[0]
        await deliver(fix(at: trailhead))
        let cold = try #require(SharedStore.load()?.liveFix)
        #expect(cold.distanceAlongRouteMeters < total / 2, "with nothing to go on, a fix here is the start")

        // Now the app is relaunched knowing the walker was nearly home. The
        // wait above is what makes this safe to write here: matching reads the
        // reference off the main actor now, so seeding it while the previous
        // fix was still in flight would decide nothing.
        defaults.set(total, forKey: SettingsKey.lastMatchedDistance)
        await deliver(fix(at: trailhead))

        let resumed = try #require(SharedStore.load()?.liveFix)
        #expect(
            resumed.distanceAlongRouteMeters > total / 2,
            "a walker finishing an out-and-back must not be reported as just starting it"
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
        #expect(abs(try #require(persisted) - profile.distances[3]) < 1)
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
    /// walker leaves its route, and leaving used to be reported only by the
    /// detail view's own matcher — so a walker who tapped End, locked the
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
    /// the walker is relative to the trail — including whether they left it —
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

// MARK: - Selection arming

extension WidgetFeedSuites {
/// Monitoring follows the *selection*, not just the settings toggle.
///
/// Serialized with the other feed suites: selecting a hike publishes a
/// snapshot to the App Group file they share, even though nothing here
/// asserts on it.
@Suite("Background tracking selection arming", .serialized)
final class BackgroundTrackingSelectionTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    // periphery:ignore - assigned and never read on purpose; it is the strong
    // reference that keeps the tracker alive.
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

    /// The state a user who has turned the feature on and answered the prompt
    /// is in: everything armed except for the selection each test supplies.
    private func makeTracker(selecting hike: Hike? = nil) -> BackgroundTrailTracker {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always
        if let hike { defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID) }
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    private func hike() -> Hike {
        let newHike = Fixture.hike(in: context)
        try? context.save()
        return newHike
    }

    /// The reported bug: closing the trail left significant-change monitoring
    /// armed for good, because the only thing that ever stopped it was the
    /// settings toggle — which the user has no reason to touch.
    @Test("deselecting the trail stops monitoring")
    func deselectingStops() {
        let tracker = makeTracker(selecting: hike())
        #expect(monitor.isMonitoring, "precondition: a launch with a selection arms")

        tracker.hikeSelectionChanged(to: nil)

        #expect(monitor.stopCount == 1)
        #expect(!monitor.isMonitoring, "no trail, nothing for a wake-up to do")
    }

    /// And the toggle stays on across it: it is a standing preference, so
    /// picking a trail again has to arm monitoring without the user going
    /// back to Settings.
    @Test("selecting a trail with tracking already on arms monitoring")
    func selectingArms() {
        let tracker = makeTracker()
        #expect(monitor.startCount == 0, "precondition: nothing selected, nothing armed")

        tracker.hikeSelectionChanged(to: hike())

        #expect(monitor.startCount == 1)
        #expect(monitor.isMonitoring)
    }

    /// The selection is one of three conditions, not a replacement for the
    /// other two.
    @Test("selecting a trail with tracking off arms nothing")
    func selectingWithTrackingOffArmsNothing() {
        let tracker = makeTracker()
        defaults.set(false, forKey: SettingsKey.backgroundTrackingEnabled)

        tracker.hikeSelectionChanged(to: hike())

        #expect(monitor.startCount == 0)
    }

    /// Swapping one trail for another is a selection the feed can serve, so
    /// it must not stand monitoring down on the way through.
    @Test("swapping one trail for another leaves monitoring armed")
    func swappingTrailsStaysArmed() {
        let tracker = makeTracker(selecting: hike())

        tracker.hikeSelectionChanged(to: hike())

        #expect(monitor.isMonitoring)
        #expect(monitor.stopCount == 0)
    }
}
}
