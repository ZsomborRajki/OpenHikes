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
    ///
    /// Pinned to the walked hike while a walk is under way — see
    /// ``walkDidStart(hikeID:)``.
    private(set) var trackedHikeID: UUID?
    /// The hike being walked, which outranks the selection for as long as
    /// the walk lives: a walker who locks the phone, or who opens another
    /// trail to compare it, keeps accruing coverage on significant-change
    /// updates against the trail they are actually on.
    private(set) var walkedHikeID: UUID?
    /// A selection change that arrived while a walk held the tracked hike,
    /// applied when the walk ends. A box rather than a bare optional because
    /// "deselected" and "never changed" are different answers.
    private var deferredSelection: DeferredSelection?
    /// Where a background match's coverage goes. Weak because the session
    /// holds this tracker, and both live for the app's life either way.
    weak var walkSession: TrailWalkSession?
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
    ///   - widgetReload: the redraw seam. A suite hands this a counter so
    ///     that a call site going back to `WidgetCenter` directly — and so
    ///     bypassing the recording gate — fails a test instead of quietly
    ///     spending the reload budget. See ``TrailWidgetReload``.
    init(
        container: ModelContainer,
        monitor: (any SignificantLocationMonitor)? = nil,
        defaults: UserDefaults = .standard,
        liveActivityController: HikeLiveActivityController? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        widgetReload: TrailWidgetReload = .system
    ) {
        let initialGeneration = SelectionGeneration()
        self.container = container
        self.monitor = monitor ?? CLLocationManager()
        self.defaults = defaults
        self.liveActivityController = liveActivityController
        self.clock = clock
        selectionGeneration = initialGeneration
        snapshotWriter = SnapshotWriter(generation: initialGeneration, widgetReload: widgetReload)
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
        // A walk holds the tracked hike, the widget and the Lock Screen until
        // it ends — opening another trail to compare it is not leaving the
        // walk. The selection is remembered and applied at the end.
        if walkedHikeID != nil {
            deferredSelection = DeferredSelection(hike: hike)
            return
        }
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
    ///
    /// - Parameter walk: what the walk along this hike has recorded so far,
    ///   or `nil` when nothing is being walked. Written into the snapshot
    ///   beside the fix, so the widget and the Lock Screen read coverage and
    ///   position from the same bytes.
    func publishLiveFix(
        hike: Hike,
        profile: RouteProfile,
        match: (distanceAlongRoute: Double, offRouteMeters: Double)?,
        walk: SharedTrailSnapshot.Walk? = nil
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
            updateStoredLiveFix(nil, input: input, elevation: profile.elevation, walk: walk)
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
            elevation: profile.elevation,
            walk: walk
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
        // Before the match rather than inside it, and before the tracked hike
        // is even read. Matching is the only thing that used to reach the
        // session here, so a walker who left the trail produced nothing but
        // unmatched significant changes and the six-hour rule never fired
        // while the app stayed backgrounded — the widget and the Lock Screen
        // kept an off-trail walk indefinitely. The foreground path checks on
        // every fix; this is the same check on every accepted one.
        walkSession?.endIfAbandoned()
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
            if let distance = matched.matchedDistance {
                lastMatchedDistance = distance
                // Coverage accrues from here too — this is the feed that
                // keeps a walk honest while the phone is in a pocket.
                let completedWalk = walkSession?.recordBackgroundMatch(
                    hikeID: hikeID,
                    distance: distance,
                    at: timestamp
                ) ?? false
                // A fix that completed the walk is not published: the write
                // below would carry no walk and start a plain follow over the
                // finished panel `walkDidEnd` has just queued.
                if completedWalk { return }
            } else {
                // Off the trail, and the session has to hear it: leaving the
                // route is the boundary an End waits for, and until this the
                // only thing that ever reported one was the detail view's own
                // matcher. A walker who tapped End, pocketed the phone, left
                // and came back found the first foreground match still
                // refused — the leave had happened where nothing was looking.
                // A rejected fix never gets here, so "off route" still means
                // matched and found off it rather than no usable evidence.
                walkSession?.recordOffRoute(hikeID: hikeID)
            }
            // A paused walk neither extends the union nor publishes: the
            // widget already says Paused, and a moving dot would contradict it.
            guard walkSession?.publishes(hikeID: hikeID) ?? true else { return }
            updateStoredLiveFix(
                matched.fix,
                input: matched.input,
                elevation: matched.elevation,
                walk: walkSession?.payload(for: hikeID)
            )
        }
    }

    /// Releases the in-flight matching handle, whichever way it ended.
    /// Sequence-guarded because a newer fix has already stored its own task
    /// there, and clearing that would let a wait resolve on work still running.
    private func finishBackgroundMatch(sequence: UInt64) {
        guard backgroundMatchSequence == sequence else { return }
        backgroundMatchTask = nil
    }

    // MARK: Walks

    /// A selection remembered while a walk held the tracked hike.
    struct DeferredSelection {
        let hike: Hike?
    }

    /// Pins the tracked hike to the one being walked.
    ///
    /// A walk starts on a matched fix in the walked hike's own detail view,
    /// so the two already agree — except after a relaunch, where the tracked
    /// hike was seeded from the *last selection* and the walk restored from
    /// disk is the one a background fix has to be matched against. That is
    /// the relaunch this pin exists for.
    func walkDidStart(hikeID: UUID) {
        walkedHikeID = hikeID
        guard trackedHikeID != hikeID else { return }
        trackedHikeID = hikeID
        lastMatchedDistance = nil
        lastForegroundPublish = nil
        lastStatusFlipPublish = nil
        syncMonitoring()
    }

    /// Releases the pin, clears the walk from the widget, ends the Lock
    /// Screen panel — lingering with `final`, or at once with `nil` — and
    /// applies whatever selection arrived meanwhile.
    ///
    /// - Parameter final: the walk's closing figures, for the panel to show
    ///   for `HikeLiveActivityController.finishedDismissAfter`. `nil` for a
    ///   walk that was abandoned or not kept, which leaves nothing behind
    ///   — the same rule a discarded recording follows.
    func walkDidEnd(final: SharedTrailSnapshot.Walk?) {
        guard let hikeID = walkedHikeID else { return }
        walkedHikeID = nil
        // The revision this walk's last write is gated on. Applying the
        // deferred selection bumps it, which is why that now happens inside
        // the completion below and not beside it: done first, it rejected the
        // terminal write and the panel was left on screen with no result on
        // it — or ended at once with nothing, which is what an abandoned walk
        // gets and not what a finished one does.
        let revision = selectionRevision
        updateStoredWalk(nil, hikeID: hikeID) { [weak self] snapshot in
            guard let self else { return }
            // The result is built from what actually landed; the panel comes
            // down either way, since a skipped write is no reason to leave a
            // finished walk on the Lock Screen.
            let finalState = final.flatMap { walk -> HikeActivityAttributes.ContentState? in
                guard var closing = snapshot else { return nil }
                closing.walk = walk
                return .init(following: closing)
            }
            endFollowActivity(
                hikeID: hikeID,
                finalState: finalState,
                dismissAfter: finalState == nil ? nil : HikeLiveActivityController.finishedDismissAfter
            )
            applyDeferredSelection(ifRevisionIs: revision)
        }
    }

    /// Applies a selection remembered while the walk held the tracked hike.
    ///
    /// Dropped rather than applied when the revision has moved on: a newer
    /// selection arrived after the walk released the pin and has already been
    /// applied, and re-applying the remembered one would take the walker back
    /// to a trail they left.
    private func applyDeferredSelection(ifRevisionIs revision: UInt64) {
        guard let deferred = deferredSelection else { return }
        deferredSelection = nil
        guard selectionRevision == revision else { return }
        hikeSelectionChanged(to: deferred.hike)
    }

    /// Puts a pause or a resume in front of the walker at once.
    func walkStateDidChange(_ walk: SharedTrailSnapshot.Walk, hikeID: UUID) {
        updateStoredWalk(walk, hikeID: hikeID) { [weak self] snapshot in
            guard let snapshot else { return }
            self?.publishFollowActivity(snapshot)
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
        elevation: RouteElevationSummary,
        walk: SharedTrailSnapshot.Walk?
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
                      walk: walk,
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

    /// Replaces just the walk portion of the stored snapshot — a pause, a
    /// resume, an end — leaving the fix and the trail as they are, and hands
    /// what landed to `then` on the same chain the fixes ride.
    ///
    /// The status-change bypass for a walk, in effect: the widget is redrawn
    /// and the Lock Screen offered the new run state at once, through the
    /// same funnel a fix goes through, so a Paused that arrives between two
    /// fixes cannot be overwritten by the earlier of them landing late.
    ///
    /// - Parameter completion: handed what landed, or `nil` for a write the
    ///   store skipped — a snapshot for another trail, or a selection that
    ///   arrived while this was in flight. Called either way, because the end
    ///   of a walk has work that has to happen whether or not the widget took
    ///   the write: see ``walkDidEnd(final:)``.
    func updateStoredWalk(
        _ walk: SharedTrailSnapshot.Walk?,
        hikeID: UUID,
        then completion: @escaping @MainActor (SharedTrailSnapshot?) -> Void = { _ in /* no-op default */ }
    ) {
        let revision = selectionRevision
        let previous = fixPublishTask
        let pendingSelection = selectionPublishTask
        fixPublishSequence &+= 1
        let sequence = fixPublishSequence
        fixPublishTask = Task { [weak self] in
            defer { self?.finishFixPublish(sequence: sequence) }
            await previous?.value
            await pendingSelection?.value
            guard let self else { return }
            var written: SharedTrailSnapshot?
            if let snapshot = await snapshotWriter.applyWalk(walk, hikeID: hikeID, ifCurrent: revision),
               selectionRevision == revision {
                await snapshotWriter.reloadWidget()
                written = snapshot
            }
            completion(written)
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
