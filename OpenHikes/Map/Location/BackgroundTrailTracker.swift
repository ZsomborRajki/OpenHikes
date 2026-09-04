//
//  BackgroundTrailTracker.swift
//  OpenHikes
//
//  Keeps the widget trail snapshot fresh from two independent feeds:
//  a throttled foreground push (`publishLiveFix`, called from
//  HikeDetailView's existing auto-follow loop — no extra permission needed)
//  and a background one, driven by significant-location-change delivery,
//  which can relaunch this app after it's been suspended or terminated.
//
//  Deliberately a *separate* CLLocationManager from LocationManager — that
//  one's continuous, when-in-use, foreground-tuned behavior (see its own
//  header comment) is left untouched. This manager only ever asks for Always
//  authorization, and only once the user turns on Background Trail Tracking
//  in Settings.
//
//  Significant-change monitoring (unlike continuous background updates)
//  relies on neither `allowsBackgroundLocationUpdates` nor the "Location
//  updates" background mode — the app declares both, but only the hike
//  recorder uses them (see `HikeRecorder+State`). That's what keeps this feed
//  battery-friendly and free of the persistent background-location indicator.
//
//  It does not make the feed free, though: iOS's periodic "has been using
//  your location in the background" reminder is keyed on background location
//  *use*, not on the indicator, and every significant change wakes or
//  relaunches this app. So monitoring is armed only while it has something to
//  do — see ``syncMonitoring(trackingEnabled:)``.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesShared
import SwiftData
import Synchronization

/// The slice of `CLLocationManager` this tracker uses: authorization, and
/// significant-location-change delivery.
///
/// Exists so the background-relaunch path has a seam. It is the app's least
/// testable surface and its most failure-prone one — a relaunch has no
/// in-memory state, so everything it does is decided by authorization, by
/// what `UserDefaults` says the selection was, and by a fix arriving through a
/// delegate callback. None of those three could be driven from a test while
/// this was a `private let manager = CLLocationManager()`.
///
/// The members are renamed rather than reusing `CLLocationManager`'s own, and
/// authorization is exposed as two questions rather than as a
/// `CLAuthorizationStatus`: neither `.authorizedAlways` nor the
/// significant-change API exists on every Apple platform the sources still
/// guard for. The `#if os(iOS)` guards therefore live in the adapter below,
/// and the tracker itself has one code path — which is also the one the tests
/// drive.
protocol SignificantLocationMonitor: AnyObject {
    /// Whether Always authorization is granted right now.
    var isAlwaysAuthorized: Bool { get }
    /// Whether asking for it could still change that — i.e. the user has
    /// neither granted nor refused it yet.
    var canRequestAlwaysAccess: Bool { get }

    var monitorDelegate: CLLocationManagerDelegate? { get set }

    func requestAlwaysAccess()
    func startSignificantLocationUpdates()
    func stopSignificantLocationUpdates()
}

extension CLLocationManager: SignificantLocationMonitor {
    var isAlwaysAuthorized: Bool {
        #if os(iOS)
        authorizationStatus == .authorizedAlways
        #else
        false
        #endif
    }

    var canRequestAlwaysAccess: Bool {
        #if os(iOS)
        switch authorizationStatus {
        case .notDetermined, .authorizedWhenInUse: true
        default: false
        }
        #else
        false
        #endif
    }

    var monitorDelegate: CLLocationManagerDelegate? {
        get { delegate }
        set { delegate = newValue }
    }

    func requestAlwaysAccess() {
        #if os(iOS)
        requestAlwaysAuthorization()
        #endif
    }

    func startSignificantLocationUpdates() {
        #if os(iOS)
        startMonitoringSignificantLocationChanges()
        #endif
    }

    func stopSignificantLocationUpdates() {
        #if os(iOS)
        stopMonitoringSignificantLocationChanges()
        #endif
    }
}

@Observable
final class BackgroundTrailTracker: NSObject {
    private let monitor: any SignificantLocationMonitor
    private let defaults: UserDefaults
    /// The Lock Screen, when the app has one. A trail being followed is the
    /// second thing this app can put there — see
    /// ``publishFollowActivity(_:)``. Optional so a suite gets a tracker that
    /// cannot reach ActivityKit.
    let liveActivityController: HikeLiveActivityController?
    /// Reads the current time for the two throttles below — injectable so a
    /// test can step across a 45-second window rather than wait it out.
    let clock: @Sendable () -> Date
    private let container: ModelContainer
    /// The hike background delivery should match fixes against. Seeded at
    /// launch from `SettingsKey.lastSelectedHikeID` (written by `OpenHikesModel`)
    /// since a background relaunch has no in-memory selection to read.
    private var trackedHikeID: UUID?
    /// Invalidates detached selection work when a newer selection arrives.
    private var selectionRevision: UInt64 = 0
    private var selectionPublishTask: Task<Void, Never>?
    private let selectionGeneration: SelectionGeneration
    private let snapshotWriter: SnapshotWriter

    /// The background fix currently being matched against the route, and the
    /// counter that bounds a wait on it.
    ///
    /// One handle rather than one per fix, because each publication awaits the
    /// one it replaced: matching reads ``lastMatchedDistance`` and writes it
    /// back, so two fixes matched concurrently would each continue from where
    /// the walker was *before* the other one — which on a loop or an
    /// out-and-back is the exact ambiguity that reference exists to resolve.
    private var backgroundMatchTask: Task<Void, Never>?
    private var backgroundMatchSequence: UInt64 = 0

    /// The App Group write currently in flight for the live fix, and the
    /// counter that bounds a wait on it. Chained for ordering — see
    /// ``updateStoredLiveFix(_:input:elevation:)``.
    private var fixPublishTask: Task<Void, Never>?
    private var fixPublishSequence: UInt64 = 0

    /// Last distance-along-route a fix was actually matched at — the
    /// continuity reference `RouteProfile.nearestPoint` needs so GPS noise on
    /// loops/switchbacks can't jump the match. Persisted so it survives a
    /// background relaunch, which starts with no in-memory state at all.
    private var lastMatchedDistance: Double? {
        get {
            defaults.object(forKey: SettingsKey.lastMatchedDistance) != nil
                ? defaults.double(forKey: SettingsKey.lastMatchedDistance)
                : nil
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: SettingsKey.lastMatchedDistance)
            } else {
                defaults.removeObject(forKey: SettingsKey.lastMatchedDistance)
            }
        }
    }

    /// Throttles `publishLiveFix`: only actually writes roughly every
    /// `foregroundPublishInterval`, or immediately when on/off-route status
    /// flips — avoids spending the widget's reload budget on a per-second feed.
    private var lastForegroundPublish: (date: Date, wasOnRoute: Bool)?
    private static let foregroundPublishInterval: TimeInterval = 45

    /// When the status-flip bypass was last taken.
    ///
    /// The bypass exists so that genuinely losing the trail reaches the widget
    /// at once rather than up to 45 s later, and that's worth keeping — but
    /// unbounded it is a hole straight through the throttle it bypasses. A
    /// walker flipping on and off with ordinary GPS noise took it on every fix,
    /// each time costing a `SharedStore.load`, a re-encode, an atomic App Group
    /// write and a `WidgetCenter.reloadTimelines`. WidgetKit throttles a widget
    /// that overruns its daily reload budget, so the unbounded bypass degrades
    /// the very feature it's trying to keep fresh.
    private var lastStatusFlipPublish: Date?
    /// Floor under that bypass: the first flip is immediate, a second one waits.
    private static let statusFlipInterval: TimeInterval = 30

    /// How far off the trail counts as having left it, once already on it.
    ///
    /// Hysteresis, so a fix hovering either side of the follow threshold isn't
    /// a status change at all. Coming *back* still uses the plain threshold, so
    /// regaining the trail is as prompt as it ever was; only leaving it is
    /// grudging, and only by the width of this band.
    private static let offRouteExitHysteresisMultiplier: Double = 1.5
    private static let offRouteExitMeters = RouteProfile.followMatchThresholdMeters * offRouteExitHysteresisMultiplier

    /// - Parameters:
    ///   - monitor: significant-change delivery. Deliberately a *separate*
    ///     manager from `LocationManager`'s — see the file comment.
    ///   - defaults: where the selection, the settings toggle and the matching
    ///     continuity reference are read from. A test passes a suite of its
    ///     own rather than editing the ones the host app is using.
    ///   - clock: reads the current time for the publish throttles.
    init(
        container: ModelContainer,
        monitor: (any SignificantLocationMonitor)? = nil,
        defaults: UserDefaults = .standard,
        liveActivityController: HikeLiveActivityController? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let initialGeneration = SelectionGeneration()
        self.container = container
        self.monitor = monitor ?? CLLocationManager()
        self.defaults = defaults
        self.liveActivityController = liveActivityController
        self.clock = clock
        selectionGeneration = initialGeneration
        snapshotWriter = SnapshotWriter(generation: initialGeneration)
        super.init()
        self.monitor.monitorDelegate = self
        trackedHikeID = UUID(uuidString: defaults.string(forKey: SettingsKey.lastSelectedHikeID) ?? "")
        // Re-arm on every launch: the system wakes the app specifically so it
        // can call this again and receive the pending event — monitoring
        // doesn't itself persist across process launches. The same call is
        // what stands monitoring *down* on a launch that shouldn't have it,
        // which is the one place a registration left over from a previous
        // launch can be cancelled.
        syncMonitoring()
    }

    // MARK: Settings toggle

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            monitor.stopSignificantLocationUpdates()
            return
        }
        if monitor.isAlwaysAuthorized {
            syncMonitoring(trackingEnabled: true)
        } else if monitor.canRequestAlwaysAccess {
            // Asked for even with no hike selected: the toggle is a standing
            // preference, and the grant is a trip out of the app the user
            // shouldn't have to make again the moment they pick a trail. The
            // answer arrives at `authorizationChanged()`.
            monitor.requestAlwaysAccess()
        }
        // Denied or restricted: nothing to ask and nothing to start.
    }

    /// Brings monitoring in line with the one condition under which it is
    /// worth having armed.
    ///
    /// Three conditions, not two: the selection belongs here as much as the
    /// toggle and the authorization do. Armed without a hike, every
    /// significant change — one every few hundred metres of driving — wakes
    /// or relaunches the app only for `handleBackgroundFix` to return at its
    /// `trackedHikeID` guard, having already paid for the launch. A long
    /// drive's worth of those is precisely the usage iOS's periodic
    /// background-location reminder exists to surface, so an idle armed feed
    /// costs the user prompts as well as battery.
    ///
    /// Every arming site goes through here rather than calling the monitor
    /// directly, so the condition can't drift apart between them — the bug
    /// this replaces was three `start` sites agreeing with each other and
    /// none of them agreeing with the fix handler. Both calls are idempotent,
    /// so re-stating the state monitoring is already in is free.
    ///
    /// - Parameter trackingEnabled: the settings toggle's value. `setEnabled`
    ///   passes its own argument, so arming doesn't depend on whether the
    ///   `@AppStorage` binding behind the switch has written the new value yet.
    private func syncMonitoring(trackingEnabled: Bool) {
        if trackingEnabled, monitor.isAlwaysAuthorized, trackedHikeID != nil {
            monitor.startSignificantLocationUpdates()
        } else {
            monitor.stopSignificantLocationUpdates()
        }
    }

    /// The same, for the callers with no toggle value in hand — a launch, an
    /// authorization change, a selection — which read the stored one.
    private func syncMonitoring() {
        syncMonitoring(trackingEnabled: defaults.bool(forKey: SettingsKey.backgroundTrackingEnabled))
    }

    // MARK: Selection

    /// Called whenever the app's selected hike changes. Snapshots the SwiftData
    /// values on-main, then prepares and writes the widget payload off-main so
    /// a long GPX cannot consume most of the tap's frame.
    func hikeSelectionChanged(to hike: Hike?) {
        // Before the id changes, so the activity that comes down is the one
        // for the trail being left rather than a lookup against the new one.
        if hike?.id != trackedHikeID { endFollowActivity(hikeID: nil) }
        trackedHikeID = hike?.id
        // The selection is half of what decides whether monitoring should be
        // running at all, so deselecting is what stands it down: nothing else
        // will, and the settings toggle deliberately stays on across it.
        syncMonitoring()
        lastMatchedDistance = nil
        lastForegroundPublish = nil
        lastStatusFlipPublish = nil
        selectionRevision &+= 1
        let revision = selectionRevision
        selectionGeneration.update(to: revision)
        selectionPublishTask?.cancel()

        guard let hike, hike.pointCount > 1 else {
            // Not necessarily `nil`: a hike with one point or none is also
            // nothing to draw, and it is still the selection. Comparing
            // against the id captured here rather than against `nil` is what
            // lets that case finish — guarding on `trackedHikeID == nil`
            // returned early for it, leaving the widget on the *previous*
            // trail (cleared from the store but never reloaded), the old
            // basemaps un-invalidated, and `selectionPublishTask` non-nil,
            // which shuts off `publishLiveFix` for as long as it is selected.
            let clearedSelectionID = hike?.id
            selectionPublishTask = Task { [weak self] in
                defer { self?.finishSelectionPublish(revision: revision) }
                guard let self,
                      await snapshotWriter.clear(ifCurrent: revision),
                      selectionRevision == revision,
                      trackedHikeID == clearedSelectionID
                else { return }
                await TrailBasemapRenderer.shared.invalidate()
                guard selectionRevision == revision else { return }
                await snapshotWriter.reloadWidget()
            }
            return
        }
        let input = SnapshotInput(hike: hike)
        selectionPublishTask = Task { [weak self] in
            defer { self?.finishSelectionPublish(revision: revision) }
            guard !Task.isCancelled else { return }
            let snapshot = await Self.buildSnapshotOffMain(from: input, liveFix: nil)
            guard let snapshot,
                  let self,
                  !Task.isCancelled,
                  selectionRevision == revision,
                  trackedHikeID == input.hikeID,
                  await snapshotWriter.save(snapshot, ifCurrent: revision),
                  selectionRevision == revision,
                  trackedHikeID == input.hikeID
            else { return }
            await snapshotWriter.reloadWidget()
            refreshBasemaps(for: snapshot)
        }
    }

    /// Releases the in-flight handle once a publication ends, whichever way it
    /// ended.
    ///
    /// It has to be every exit, not just the successful one: `publishLiveFix`
    /// reads this property as "a snapshot is still being written, don't race
    /// it", so a publication that returned through one of its guards without
    /// clearing it would silently stop the live feed until the next selection.
    /// Revision-guarded because a *newer* selection has already stored its own
    /// task here, and clearing that would hand the same window to the feed.
    private func finishSelectionPublish(revision: UInt64) {
        guard selectionRevision == revision else { return }
        selectionPublishTask = nil
    }

    /// Whether a selection publication is still in flight.
    ///
    /// A test seam. The property it reports gates `publishLiveFix`, and the
    /// failure it exists to catch — a publication ending without releasing it —
    /// is invisible from the outside: the store looks right and the feed is
    /// simply dead.
    var isPublishingSelection: Bool { selectionPublishTask != nil }

    /// Waits for the latest selection publication. The detail view uses this
    /// before starting its live-fix loop so the first fix cannot race and be
    /// overwritten by the trail's initial snapshot.
    ///
    /// Loops rather than awaiting once, because "the latest" can change while
    /// this is suspended: a selection arriving mid-wait cancels the task being
    /// awaited, and a cancelled task returns through its guards almost at once.
    /// Awaiting once would therefore resolve *earlier* than a quiet wait would,
    /// and hand the caller a store still holding the previous trail.
    ///
    /// The revision also bounds the loop, so a handle left behind by some
    /// future path that forgets to release it is a stale flag rather than a
    /// spin: an already-finished task at an unchanged revision ends the wait.
    func waitForSelectionPublish() async {
        var awaitedRevision: UInt64?
        while let task = selectionPublishTask, awaitedRevision != selectionRevision {
            awaitedRevision = selectionRevision
            await task.value
        }
    }

    // MARK: Widget basemaps

    /// Re-checks the widget's rendered basemaps against whatever trail is
    /// currently stored, rendering only if they no longer frame it. Called on
    /// every foreground as well as on selection, because rendering needs the
    /// network: a trail selected offline — or one whose images a background
    /// relaunch couldn't produce — gets its map the next time the app is
    /// opened somewhere with a connection.
    ///
    /// The read goes through the writer for the same reason the writes do:
    /// every foreground calls this, and decoding the snapshot is an App Group
    /// file read that has no business on the frame that brought the app back.
    func refreshBasemaps() {
        Task { [weak self] in
            guard let writer = self?.snapshotWriter else { return }
            guard let snapshot = await writer.load(), let self else { return }
            refreshBasemaps(for: snapshot)
        }
    }

    private func refreshBasemaps(for snapshot: SharedTrailSnapshot) {
        // Framed from the same decimated polyline the widget draws, so the
        // rendered region can't disagree with the line drawn over it.
        Task {
            await TrailBasemapRenderer.shared.refreshIfNeeded(
                hikeID: snapshot.hikeID,
                polyline: snapshot.polyline
            )
        }
    }

    // MARK: Foreground feed

    /// Called from `HikeDetailView`'s auto-follow loop, which advances once per
    /// published fix. Throttled internally — does not write on every call.
    func publishLiveFix(
        hike: Hike,
        profile: RouteProfile,
        match: (distanceAlongRoute: Double, offRouteMeters: Double)?
    ) {
        // The first poll waits for selection publication in HikeDetailView.
        // Keep this guard as a backstop for any other caller; the next poll
        // retries rather than racing the initial snapshot.
        guard hike.id == trackedHikeID, selectionPublishTask == nil else { return }

        // Leaving the trail takes the wider threshold, rejoining it the normal
        // one, so noise around the follow distance doesn't read as a status
        // change in the first place.
        let wasOnRoute = lastForegroundPublish?.wasOnRoute ?? false
        let threshold = wasOnRoute ? Self.offRouteExitMeters : RouteProfile.followMatchThresholdMeters
        let isOnRoute = (match?.offRouteMeters).map { $0 <= threshold } ?? false

        let now = clock()
        if let last = lastForegroundPublish {
            let intervalElapsed = now.timeIntervalSince(last.date) >= Self.foregroundPublishInterval
            // A flip may bypass the interval, but not more often than
            // `statusFlipInterval` — the first one is free, the flapping isn't.
            let flipped = isOnRoute != last.wasOnRoute
            let flipAllowed = flipped
                && (lastStatusFlipPublish.map { now.timeIntervalSince($0) >= Self.statusFlipInterval } ?? true)
            guard intervalElapsed || flipAllowed else { return }
            if flipAllowed { lastStatusFlipPublish = now }
        }
        lastForegroundPublish = (now, isOnRoute)

        // Values, taken here because a `Hike` belongs to its context and
        // cannot leave the main actor. Everything the write path does with
        // them happens off it.
        let input = SnapshotInput(hike: hike)
        guard isOnRoute, let match, let coordinate = profile.coordinate(atDistance: match.distanceAlongRoute) else {
            updateStoredLiveFix(nil, input: input, elevation: profile.elevation)
            return
        }
        lastMatchedDistance = match.distanceAlongRoute
        updateStoredLiveFix(
            SharedTrailSnapshot.LiveFix(
                coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                distanceAlongRouteMeters: match.distanceAlongRoute,
                offRouteMeters: match.offRouteMeters,
                timestamp: .now,
                elevationMeters: profile.sample(atDistance: match.distanceAlongRoute)?.elevation
            ),
            input: input,
            elevation: profile.elevation
        )
    }

    // MARK: Background feed

    /// Matches a significant-change fix against the persisted selection and
    /// publishes it.
    ///
    /// The main actor's share is the fix policy check and nothing else. What
    /// follows it — reading the hike, building a `RouteProfile` and projecting
    /// the fix onto it — is a route-sized SwiftData materialisation and then
    /// O(route points) twice over, and this is the feed that pays it in full:
    /// a relaunched process has no profile in memory, so a hike imported from
    /// a five-hour GPX rebuilds all twenty thousand points before it can say
    /// where the walker is.
    private func handleBackgroundFix(_ location: CLLocation) {
        // Significant-location-change delivery can include stale cached fixes
        // on relaunch. Matching also requires uncertainty no wider than the
        // same route tolerance used by foreground tracking.
        guard LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.backgroundMaximumAge,
            maximumHorizontalAccuracy: RouteProfile.followMatchThresholdMeters
        ) else { return }
        // Kept even though monitoring is now disarmed on deselection: a fix
        // already in flight can still land in the window between the two.
        guard let hikeID = trackedHikeID else { return }
        // The other end of the funnel `BackgroundFixDelivered` opens: a fix
        // this tracker is about to spend a match on. The gap between the two
        // is wake-ups that bought nothing — a stale cached fix on relaunch, or
        // a wake with no hike selected to match against.
        RenderSignpost.mark("BackgroundFixMatched")

        let modelContainer = container
        let coordinate = location.coordinate
        let heading = LocationFixPolicy.course(of: location)
        let timestamp = location.timestamp
        let revision = selectionRevision
        let previous = backgroundMatchTask
        backgroundMatchSequence &+= 1
        let sequence = backgroundMatchSequence
        backgroundMatchTask = Task { [weak self] in
            defer { self?.finishBackgroundMatch(sequence: sequence) }
            // Strictly after the fix before it, so the continuity reference
            // read below is the one that fix actually matched at.
            await previous?.value
            guard let self, selectionRevision == revision, trackedHikeID == hikeID else { return }
            // No equivalent of `HikeDetailView`'s re-seeding rule is needed
            // here: significant-location-change delivery only happens because
            // the device moved several hundred metres, so a fix that arrives
            // without a usable course is the rare one — and whenever the
            // detail view has been open, `publishLiveFix` has already left a
            // course-settled `lastMatchedDistance` behind to continue from.
            let reference = lastMatchedDistance
            let matched = await Self.offMainThread {
                Self.match(
                    hikeID: hikeID,
                    in: modelContainer,
                    to: coordinate,
                    near: reference,
                    heading: heading,
                    timestamp: timestamp
                )
            }
            guard let matched, selectionRevision == revision, trackedHikeID == hikeID else { return }
            // An unmatched fix leaves the reference alone: it says nothing
            // about where along the route the walker is.
            if let distance = matched.matchedDistance { lastMatchedDistance = distance }
            updateStoredLiveFix(matched.fix, input: matched.input, elevation: matched.elevation)
        }
    }

    /// Releases the in-flight matching handle, whichever way it ended.
    /// Sequence-guarded because a newer fix has already stored its own task
    /// there, and clearing that would let a wait resolve on work still running.
    private func finishBackgroundMatch(sequence: UInt64) {
        guard backgroundMatchSequence == sequence else { return }
        backgroundMatchTask = nil
    }

    /// The revision of the current selection, shared between the main-actor
    /// tracker that bumps it and the detached snapshot work that has to ask
    /// whether its result is still wanted.
    ///
    /// A box rather than a plain `UInt64` because those two hold the same
    /// counter, and `Atomic` — which is what a shared scalar needs, without
    /// the mutual exclusion a mutex would also impose — makes it `Sendable`
    /// outright instead of by assertion.
    nonisolated private final class SelectionGeneration: Sendable {
        private let value = Atomic<UInt64>(0)

        func update(to newValue: UInt64) {
            value.store(newValue, ordering: .releasing)
        }

        func matches(_ candidate: UInt64) -> Bool {
            value.load(ordering: .acquiring) == candidate
        }
    }

    /// Every read and write of the App Group snapshot this type makes, away
    /// from the main actor. The generation gate prevents canceled selection
    /// work from committing stale data.
    ///
    /// One place rather than two, so a live fix and the trail it belongs to
    /// cannot interleave: `SharedStore` is a read-modify-write over one file,
    /// and the mutual exclusion here is what makes each of the methods below
    /// atomic against the others. It is not, on its own, enough to *order*
    /// them — an actor says nothing about which suspended caller resumes
    /// first — which is why the ordering guarantee lives at the call sites,
    /// in the task chains they await.
    private actor SnapshotWriter {
        private let generation: SelectionGeneration

        init(generation: SelectionGeneration) {
            self.generation = generation
        }

        func save(_ snapshot: SharedTrailSnapshot, ifCurrent revision: UInt64) -> Bool {
            assertOffMainThread("Widget snapshot writes must stay off the main thread")
            guard generation.matches(revision) else { return false }
            SharedStore.save(snapshot)
            return generation.matches(revision)
        }

        func clear(ifCurrent revision: UInt64) -> Bool {
            assertOffMainThread("Widget snapshot deletion must stay off the main thread")
            guard generation.matches(revision) else { return false }
            SharedStore.clear()
            return generation.matches(revision)
        }

        func load() -> SharedTrailSnapshot? {
            assertOffMainThread("Reading the widget snapshot must stay off the main thread")
            return SharedStore.load()
        }

        /// Redraws the widget unless a live recording owns it — the
        /// precedence rule, and the argument for gating it here, are in
        /// ``TrailWidgetReload``.
        ///
        /// On the writer rather than at the three call sites because the
        /// decision costs an App Group read, and every other read this feed
        /// makes is already behind this actor for exactly that reason. It
        /// deliberately takes no revision: a redraw asked for by a superseded
        /// selection is at worst a redraw of what is already on screen, and
        /// every caller has re-checked its own revision on the line above.
        func reloadWidget() { TrailWidgetReload.requestUnlessRecording() }

        /// Replaces just the live-fix portion of the stored snapshot,
        /// rebuilding the trail from `input` first when the store holds a
        /// different one — which is what a background relaunch finds, and
        /// what makes this the expensive half of the feed rather than the
        /// cheap one.
        ///
        /// Returns what landed, so the caller knows whether to re-render the
        /// widget's basemaps, or `nil` when the selection moved on while this
        /// was queued and the write would have restored a superseded trail.
        func applyLiveFix(
            _ fix: SharedTrailSnapshot.LiveFix?,
            input: SnapshotInput,
            elevation: RouteElevationSummary,
            ifCurrent revision: UInt64
        ) -> LiveFixWrite? {
            assertOffMainThread("Widget live-fix writes must stay off the main thread")
            guard generation.matches(revision) else { return nil }
            var stored = SharedStore.load()
            let isNewTrail = stored?.hikeID != input.hikeID
            if isNewTrail {
                stored = BackgroundTrailTracker.buildSnapshot(
                    from: input,
                    elevation: elevation,
                    liveFix: nil
                )
            }
            guard var snapshot = stored, generation.matches(revision) else { return nil }
            snapshot.liveFix = fix
            snapshot.updatedAt = .now
            SharedStore.save(snapshot)
            return LiveFixWrite(snapshot: snapshot, isNewTrail: isNewTrail)
        }
    }
}

/// The App Group write path shared by both feeds. In an extension rather
/// than in the class body only because a type this size has to be split
/// somewhere; everything here is main-actor state on the tracker itself.
extension BackgroundTrailTracker {
    // MARK: Shared write path

    /// Updates just the live-fix portion of the stored snapshot, off the main
    /// actor, in the order the fixes arrived.
    ///
    /// The caller has already reduced its `Hike` to values and computed the
    /// elevation summary from a profile it holds, so the rebuild below doesn't
    /// repeat that O(route points) work. What is left — reading the stored
    /// snapshot, decimating the route when the trail changed, encoding, and
    /// the atomic App Group write — is disk and arithmetic, and belongs off
    /// the frame.
    ///
    /// Ordering is by construction rather than by luck: the handle is assigned
    /// synchronously on the main actor, which serializes these calls, and every
    /// publication awaits the one it replaced before touching the store.
    /// ``SnapshotWriter`` alone would not be enough — an actor grants mutual
    /// exclusion but says nothing about the order suspended callers resume in,
    /// so two fixes could commit backwards and leave the widget showing the
    /// older one for as long as the walker kept to the same on/off-route
    /// status.
    private func updateStoredLiveFix(
        _ fix: SharedTrailSnapshot.LiveFix?,
        input: SnapshotInput,
        elevation: RouteElevationSummary
    ) {
        let revision = selectionRevision
        let previous = fixPublishTask
        // A selection publication writes the whole trail: landing a fix before
        // it would simply be overwritten by that trail's own snapshot, which
        // carries none. `publishLiveFix` refuses outright while one is in
        // flight; the background feed cannot, so it queues behind it instead.
        let pendingSelection = selectionPublishTask
        fixPublishSequence &+= 1
        let sequence = fixPublishSequence
        fixPublishTask = Task { [weak self] in
            defer { self?.finishFixPublish(sequence: sequence) }
            await previous?.value
            await pendingSelection?.value
            guard let self,
                  let write = await snapshotWriter.applyLiveFix(
                      fix,
                      input: input,
                      elevation: elevation,
                      ifCurrent: revision
                  ),
                  selectionRevision == revision
            else { return }
            await snapshotWriter.reloadWidget()
            publishFollowActivity(write.snapshot)
            // Only when the trail itself changed. A moving position needs no
            // new basemap — that's the whole reason images are affordable here.
            if write.isNewTrail { refreshBasemaps(for: write.snapshot) }
        }
    }

    /// Releases the in-flight write handle, whichever way it ended. Guarded
    /// for the same reason ``finishBackgroundMatch(sequence:)`` is.
    private func finishFixPublish(sequence: UInt64) {
        guard fixPublishSequence == sequence else { return }
        fixPublishTask = nil
    }

    /// Waits for everything the live-fix feed currently has in flight: a
    /// background fix still being matched, and the App Group write behind it.
    ///
    /// Two stages rather than one because matching *enqueues* the write, so a
    /// single wait would resolve before the store had been touched. Each stage
    /// is bounded by its own sequence for the reason
    /// ``waitForSelectionPublish()`` documents: a handle left behind by some
    /// future path that forgets to release it is a stale flag rather than a
    /// spin.
    ///
    /// A test seam. Nothing in the app waits for a fix to land — the widget
    /// reads whatever is there whenever WidgetKit asks — but a test asserting
    /// on the store has to know the write it provoked has happened.
    func waitForLiveFixPublish() async {
        var awaitedMatch: UInt64?
        while let task = backgroundMatchTask, awaitedMatch != backgroundMatchSequence {
            awaitedMatch = backgroundMatchSequence
            await task.value
        }
        var awaitedWrite: UInt64?
        while let task = fixPublishTask, awaitedWrite != fixPublishSequence {
            awaitedWrite = fixPublishSequence
            await task.value
        }
    }
}

/// Preparing what the widget stores, kept out of the tracker's own body:
/// none of it touches the tracker's state, and all of it runs off the main
/// thread.
extension BackgroundTrailTracker {
    nonisolated private struct SnapshotInput: Sendable {
        let hikeID: UUID
        let title: String
        let tintHex: String
        let totalDistanceMeters: Double
        let route: [RouteCoordinate]

        init(hike: Hike) {
            hikeID = hike.id
            title = hike.title
            tintHex = hike.tintHex
            totalDistanceMeters = hike.distanceMeters
            route = hike.route
        }
    }

    /// What a live-fix write actually put in the store, so the caller can
    /// decide whether the widget's basemaps need re-rendering without reading
    /// the file back to find out.
    nonisolated private struct LiveFixWrite: Sendable {
        let snapshot: SharedTrailSnapshot
        let isNewTrail: Bool
    }

    /// A background fix projected onto its route.
    nonisolated private struct BackgroundMatch: Sendable {
        /// The hike the fix was matched against, reduced to values off the
        /// main actor so the write path never has to reach back for it.
        let input: SnapshotInput
        /// Carried so a rebuild of the stored trail doesn't walk the route a
        /// second time to recompute what this pass already has.
        let elevation: RouteElevationSummary
        /// The published position, or `nil` when the fix did not land on the
        /// trail.
        let fix: SharedTrailSnapshot.LiveFix?
        /// Where matching should continue from next time, or `nil` to keep the
        /// existing reference.
        let matchedDistance: Double?
    }

    /// The one hop this type makes off the main actor, and the only place its
    /// off-main work is entered from.
    ///
    /// `@concurrent` rather than `Task.detached`: the work stays inside the
    /// caller's task, so cancelling that task reaches the `Task.isCancelled`
    /// guards in `buildSnapshot` directly. Detached, those guards would read
    /// the *worker's* cancellation state and could never fire — the
    /// cancellation had to be forwarded by hand through a
    /// `withTaskCancellationHandler`, and even then only landed between the
    /// stages rather than inside the route-sized work.
    ///
    /// Its own function so the guarantee has somewhere to be tested at all.
    /// What it prevents is invisible at the call site and expensive in the
    /// field: a `Task {}` started from a method on this `@MainActor` type
    /// looks exactly like `Task.detached` and runs its body on the main
    /// thread — see `CloudSyncCoordinator.offMainThread(_:)`, which exists for
    /// the same reason after that mistake shipped once.
    @concurrent
    nonisolated static func offMainThread<T: Sendable>(
        _ work: @Sendable () -> T
    ) async -> T {
        assertOffMainThread("The widget feed's route and App Group work must stay off the main thread")
        return work()
    }

    /// Reads the tracked hike and projects a background fix onto its route.
    ///
    /// The read belongs here rather than at the call site because it is the
    /// larger half: fetching a five-hour hike materialises its externally
    /// stored route before any of the arithmetic below can start, and that
    /// measured worse than the two O(route points) passes that follow it.
    /// Doing it here is safe rather than clever — `ModelContainer` is
    /// `Sendable`, and the `ModelContext` built from it is created, used and
    /// discarded inside this one call, so neither it nor the non-`Sendable`
    /// `Hike` it vends ever crosses an isolation boundary. Only the
    /// ``SnapshotInput`` of values taken from that hike leaves.
    ///
    /// Returns `nil` when the hike is gone or too short to match against.
    nonisolated private static func match(
        hikeID: UUID,
        in container: ModelContainer,
        to coordinate: CLLocationCoordinate2D,
        near referenceDistance: Double?,
        heading: CLLocationDirection?,
        timestamp: Date
    ) -> BackgroundMatch? {
        assertOffMainThread("Reading a hike for the widget feed must stay off the main thread")
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        guard let hike = (try? context.fetch(descriptor))?.first, hike.pointCount > 1 else { return nil }
        let input = SnapshotInput(hike: hike)
        let profile = RouteProfile(route: input.route)
        guard let match = profile.nearestPoint(
                to: coordinate,
                near: referenceDistance,
                heading: heading
              ),
              match.offRouteMeters <= RouteProfile.followMatchThresholdMeters,
              let matched = profile.coordinate(atDistance: match.distanceAlongRoute) else {
            return BackgroundMatch(input: input, elevation: profile.elevation, fix: nil, matchedDistance: nil)
        }
        return BackgroundMatch(
            input: input,
            elevation: profile.elevation,
            fix: SharedTrailSnapshot.LiveFix(
                coordinate: .init(latitude: matched.latitude, longitude: matched.longitude),
                distanceAlongRouteMeters: match.distanceAlongRoute,
                offRouteMeters: match.offRouteMeters,
                timestamp: timestamp,
                elevationMeters: profile.sample(atDistance: match.distanceAlongRoute)?.elevation
            ),
            matchedDistance: match.distanceAlongRoute
        )
    }

    nonisolated private static func buildSnapshotOffMain(
        from input: SnapshotInput,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) async -> SharedTrailSnapshot? {
        await offMainThread { buildSnapshot(from: input, liveFix: liveFix) }
    }

    nonisolated private static func buildSnapshot(
        from input: SnapshotInput,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) -> SharedTrailSnapshot? {
        guard !Task.isCancelled else { return nil }
        let profile = RouteProfile(route: input.route)
        guard !Task.isCancelled else { return nil }
        return buildSnapshot(
            from: input,
            elevation: profile.elevation,
            liveFix: liveFix
        )
    }

    nonisolated private static func buildSnapshot(
        from input: SnapshotInput,
        elevation: RouteElevationSummary,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) -> SharedTrailSnapshot? {
        guard !Task.isCancelled else { return nil }
        return SharedTrailSnapshot(
            hikeID: input.hikeID,
            title: input.title,
            tintHex: input.tintHex,
            totalDistanceMeters: input.totalDistanceMeters,
            polyline: decimate(input.route) { coordinate in
                SharedTrailSnapshot.CodableCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
            },
            elevationLowMeters: elevation.lowMeters,
            elevationHighMeters: elevation.highMeters,
            elevationGainMeters: elevation.gainMeters,
            elevationLossMeters: elevation.lossMeters,
            liveFix: liveFix
        )
    }
}

extension BackgroundTrailTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // The head of this manager's own funnel. Significant-change delivery
        // is cheap per fix and rare, but it is not free, and counting it here
        // is the only way a report can tell that energy apart from the map's
        // and the recorder's — the other two managers count themselves.
        RenderSignpost.mark("BackgroundFixDelivered")
        onMainActor { [weak self] in self?.handleBackgroundFix(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read back from the injected monitor rather than from the manager
        // handed in: they are the same object in the app, and only the former
        // is something a test can decide the answer for.
        onMainActor { [weak self] in self?.authorizationChanged() }
    }

    /// Arms monitoring the moment Always is granted — the grant arrives long
    /// after `setEnabled(true)` asked for it, because the user has to leave
    /// the app and answer a system prompt in between — and stands it down
    /// again if the grant is later taken away in Settings.
    private func authorizationChanged() { syncMonitoring() }
}
