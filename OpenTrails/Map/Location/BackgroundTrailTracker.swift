//
//  BackgroundTrailTracker.swift
//  OpenTrails
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
//  needs neither `allowsBackgroundLocationUpdates` nor the "Location
//  updates" background mode — both are reserved for continuous tracking,
//  which this deliberately isn't. That's what keeps this battery-friendly
//  and free of the persistent background-location indicator.
//

import Foundation
import CoreLocation
import SwiftData
import WidgetKit
import Observation
import OpenTrailsShared

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
/// significant-change API exists on every platform this app builds for. The
/// `#if os(iOS)` guards therefore live in the adapter below, and the tracker
/// itself has one code path — which is also the one the tests drive.
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
    /// Reads the current time for the two throttles below — injectable so a
    /// test can step across a 45-second window rather than wait it out.
    private let clock: @Sendable () -> Date
    private let container: ModelContainer
    /// The hike background delivery should match fixes against. Seeded at
    /// launch from `SettingsKey.lastSelectedHikeID` (written by `OpenTrailsModel`)
    /// since a background relaunch has no in-memory selection to read.
    private var trackedHikeID: UUID?
    /// Invalidates detached selection work when a newer selection arrives.
    private var selectionRevision: UInt64 = 0
    private var selectionPublishTask: Task<Void, Never>?
    private let selectionGeneration: SelectionGeneration
    private let selectionWriter: SelectionSnapshotWriter

    /// Last distance-along-route a fix was actually matched at — the
    /// continuity reference `RouteProfile.nearestPoint` needs so GPS noise on
    /// loops/switchbacks can't jump the match. Persisted so it survives a
    /// background relaunch, which starts with no in-memory state at all.
    private var lastMatchedDistance: Double? {
        get {
            defaults.object(forKey: Keys.lastMatchedDistance) != nil
                ? defaults.double(forKey: Keys.lastMatchedDistance)
                : nil
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.lastMatchedDistance)
            } else {
                defaults.removeObject(forKey: Keys.lastMatchedDistance)
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
    /// walker flipping on and off with ordinary GPS noise took it on every
    /// one-second poll, each time costing a `SharedStore.load`, a re-encode, an
    /// atomic App Group write and a `WidgetCenter.reloadTimelines`. WidgetKit
    /// throttles a widget that overruns its daily reload budget, so the
    /// unbounded bypass degrades the very feature it's trying to keep fresh.
    private var lastStatusFlipPublish: Date?
    /// Floor under that bypass: the first flip is immediate, a second one waits.
    private static let statusFlipInterval: TimeInterval = 30

    /// How far off the trail counts as having left it, once already on it.
    ///
    /// Hysteresis, so a fix hovering either side of the follow threshold isn't
    /// a status change at all. Coming *back* still uses the plain threshold, so
    /// regaining the trail is as prompt as it ever was; only leaving it is
    /// grudging, and only by the width of this band.
    private static let offRouteExitMeters = RouteProfile.followMatchThresholdMeters * 1.5

    enum Keys {
        static let lastMatchedDistance = "trailTracking.lastMatchedDistance"
    }

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
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let selectionGeneration = SelectionGeneration()
        self.container = container
        self.monitor = monitor ?? CLLocationManager()
        self.defaults = defaults
        self.clock = clock
        self.selectionGeneration = selectionGeneration
        self.selectionWriter = SelectionSnapshotWriter(generation: selectionGeneration)
        super.init()
        self.monitor.monitorDelegate = self
        trackedHikeID = UUID(uuidString: defaults.string(forKey: SettingsKey.lastSelectedHikeID) ?? "")
        // Re-arm on every launch: the system wakes the app specifically so it
        // can call this again and receive the pending event — monitoring
        // doesn't itself persist across process launches.
        if defaults.bool(forKey: SettingsKey.backgroundTrackingEnabled) {
            startIfAuthorized()
        }
    }

    // MARK: Settings toggle

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            monitor.stopSignificantLocationUpdates()
            return
        }
        if monitor.isAlwaysAuthorized {
            monitor.startSignificantLocationUpdates()
        } else if monitor.canRequestAlwaysAccess {
            // The grant, if it comes, arrives at `authorizationChanged()` —
            // the user has to leave the app to answer the prompt.
            monitor.requestAlwaysAccess()
        }
        // Denied or restricted: nothing to ask and nothing to start.
    }

    private func startIfAuthorized() {
        guard monitor.isAlwaysAuthorized else { return }
        monitor.startSignificantLocationUpdates()
    }

    // MARK: Selection

    /// Called whenever the app's selected hike changes. Snapshots the SwiftData
    /// values on-main, then prepares and writes the widget payload off-main so
    /// a long GPX cannot consume most of the tap's frame.
    func hikeSelectionChanged(to hike: Hike?) {
        trackedHikeID = hike?.id
        lastMatchedDistance = nil
        lastForegroundPublish = nil
        lastStatusFlipPublish = nil
        selectionRevision &+= 1
        let revision = selectionRevision
        selectionGeneration.update(to: revision)
        selectionPublishTask?.cancel()

        guard let hike, hike.pointCount > 1 else {
            selectionPublishTask = Task { [weak self] in
                guard let self,
                      await self.selectionWriter.clear(ifCurrent: revision),
                      self.selectionRevision == revision,
                      self.trackedHikeID == nil
                else { return }
                await TrailBasemapRenderer.shared.invalidate()
                guard self.selectionRevision == revision else { return }
                WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
                self.selectionPublishTask = nil
            }
            return
        }
        let input = SnapshotInput(hike: hike)
        selectionPublishTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let buildTask = Task.detached(priority: .userInitiated) {
                assertOffMainThread("Widget snapshot preparation must stay off the main thread")
                return Self.buildSnapshot(from: input, liveFix: nil)
            }
            let snapshot = await withTaskCancellationHandler {
                await buildTask.value
            } onCancel: {
                buildTask.cancel()
            }
            guard let snapshot,
                  let self,
                  !Task.isCancelled,
                  self.selectionRevision == revision,
                  self.trackedHikeID == input.hikeID,
                  await self.selectionWriter.save(snapshot, ifCurrent: revision),
                  self.selectionRevision == revision,
                  self.trackedHikeID == input.hikeID
            else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
            self.refreshBasemaps(for: snapshot)
            self.selectionPublishTask = nil
        }
    }

    /// Waits for the latest selection publication. The detail view uses this
    /// before starting its live-fix loop so the first fix cannot race and be
    /// overwritten by the trail's initial snapshot.
    func waitForSelectionPublish() async {
        await selectionPublishTask?.value
    }

    // MARK: Widget basemaps

    /// Re-checks the widget's rendered basemaps against whatever trail is
    /// currently stored, rendering only if they no longer frame it. Called on
    /// every foreground as well as on selection, because rendering needs the
    /// network: a trail selected offline — or one whose images a background
    /// relaunch couldn't produce — gets its map the next time the app is
    /// opened somewhere with a connection.
    func refreshBasemaps() {
        guard let snapshot = SharedStore.load() else { return }
        refreshBasemaps(for: snapshot)
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

    /// Called from `HikeDetailView`'s existing once-a-second auto-follow
    /// poll. Throttled internally — does not write on every call.
    func publishLiveFix(hike: Hike, profile: RouteProfile, match: (distanceAlongRoute: Double, offRouteMeters: Double)?) {
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

        guard isOnRoute, let match, let coordinate = profile.coordinate(atDistance: match.distanceAlongRoute) else {
            updateStoredLiveFix(nil, hike: hike, profile: profile)
            return
        }
        lastMatchedDistance = match.distanceAlongRoute
        updateStoredLiveFix(
            SharedTrailSnapshot.LiveFix(
                coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                distanceAlongRouteMeters: match.distanceAlongRoute,
                offRouteMeters: match.offRouteMeters,
                timestamp: .now
            ),
            hike: hike,
            profile: profile
        )
    }

    // MARK: Background feed

    fileprivate func handleBackgroundFix(_ location: CLLocation) {
        // Significant-location-change delivery can include stale cached fixes
        // on relaunch. Matching also requires uncertainty no wider than the
        // same route tolerance used by foreground tracking.
        guard LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.backgroundMaximumAge,
            maximumHorizontalAccuracy: RouteProfile.followMatchThresholdMeters
        ) else { return }
        guard let trackedHikeID else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == trackedHikeID })
        guard let hike = (try? context.fetch(descriptor))?.first, hike.pointCount > 1 else { return }

        let profile = RouteProfile(route: hike.route)
        // No equivalent of `HikeDetailView`'s re-seeding rule is needed here:
        // significant-location-change delivery only happens because the device
        // moved several hundred metres, so a fix that arrives without a usable
        // course is the rare one — and whenever the detail view has been open,
        // `publishLiveFix` has already left a course-settled `lastMatchedDistance`
        // behind for this to continue from.
        guard let match = profile.nearestPoint(
                to: location.coordinate,
                near: lastMatchedDistance,
                heading: LocationFixPolicy.course(of: location)
              ),
              match.offRouteMeters <= RouteProfile.followMatchThresholdMeters,
              let coordinate = profile.coordinate(atDistance: match.distanceAlongRoute) else {
            updateStoredLiveFix(nil, hike: hike, profile: profile)
            return
        }

        lastMatchedDistance = match.distanceAlongRoute
        updateStoredLiveFix(
            SharedTrailSnapshot.LiveFix(
                coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                distanceAlongRouteMeters: match.distanceAlongRoute,
                offRouteMeters: match.offRouteMeters,
                timestamp: location.timestamp
            ),
            hike: hike,
            profile: profile
        )
    }

    // MARK: Shared write path

    /// Updates just the live-fix portion of the stored snapshot. If the trail
    /// itself must be rebuilt, reuse the caller's profile rather than repeating
    /// its O(route points) distance and elevation work.
    private func updateStoredLiveFix(
        _ fix: SharedTrailSnapshot.LiveFix?,
        hike: Hike,
        profile: RouteProfile
    ) {
        var snapshot = SharedStore.load()
        let isNewTrail = snapshot?.hikeID != hike.id
        if isNewTrail {
            snapshot = Self.buildSnapshot(
                from: SnapshotInput(hike: hike),
                elevationRange: profile.elevationRange,
                liveFix: nil
            )
        }
        snapshot?.liveFix = fix
        snapshot?.updatedAt = .now
        guard let snapshot else { return }
        SharedStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
        // Only when the trail itself changed. A moving position needs no new
        // basemap — that's the whole reason images are affordable here.
        if isNewTrail { refreshBasemaps(for: snapshot) }
    }

    private nonisolated struct SnapshotInput: Sendable {
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

    private nonisolated final class SelectionGeneration: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func update(to newValue: UInt64) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func matches(_ candidate: UInt64) -> Bool {
            lock.lock()
            let matches = value == candidate
            lock.unlock()
            return matches
        }
    }

    /// Serializes App Group mutations away from the main actor. The generation
    /// gate prevents canceled selection work from committing stale data.
    private actor SelectionSnapshotWriter {
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
    }

    private static nonisolated func buildSnapshot(
        from input: SnapshotInput,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) -> SharedTrailSnapshot? {
        guard !Task.isCancelled else { return nil }
        let profile = RouteProfile(route: input.route)
        guard !Task.isCancelled else { return nil }
        return buildSnapshot(
            from: input,
            elevationRange: profile.elevationRange,
            liveFix: liveFix
        )
    }

    private static nonisolated func buildSnapshot(
        from input: SnapshotInput,
        elevationRange: ClosedRange<Double>?,
        liveFix: SharedTrailSnapshot.LiveFix?
    ) -> SharedTrailSnapshot? {
        guard !Task.isCancelled else { return nil }
        return SharedTrailSnapshot(
            hikeID: input.hikeID,
            title: input.title,
            tintHex: input.tintHex,
            totalDistanceMeters: input.totalDistanceMeters,
            elevationLowMeters: elevationRange?.lowerBound,
            elevationHighMeters: elevationRange?.upperBound,
            polyline: decimate(input.route) {
                SharedTrailSnapshot.CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            },
            liveFix: liveFix
        )
    }
}

extension BackgroundTrailTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in handleBackgroundFix(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read back from the injected monitor rather than from the manager
        // handed in: they are the same object in the app, and only the former
        // is something a test can decide the answer for.
        Task { @MainActor in authorizationChanged() }
    }

    /// Arms monitoring the moment Always is granted — the grant arrives long
    /// after `setEnabled(true)` asked for it, because the user has to leave
    /// the app and answer a system prompt in between.
    private func authorizationChanged() {
        guard monitor.isAlwaysAuthorized,
              defaults.bool(forKey: SettingsKey.backgroundTrackingEnabled) else { return }
        monitor.startSignificantLocationUpdates()
    }
}
