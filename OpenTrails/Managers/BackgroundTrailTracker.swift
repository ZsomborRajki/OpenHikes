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

@MainActor
@Observable
final class BackgroundTrailTracker: NSObject {
    private let manager = CLLocationManager()
    private let container: ModelContainer
    /// The hike background delivery should match fixes against. Seeded at
    /// launch from `SettingsKey.lastSelectedHikeID` (written by `ContentView`)
    /// since a background relaunch has no in-memory selection to read.
    private var trackedHikeID: UUID?

    /// Last distance-along-route a fix was actually matched at — the
    /// continuity reference `RouteProfile.nearestPoint` needs so GPS noise on
    /// loops/switchbacks can't jump the match. Persisted so it survives a
    /// background relaunch, which starts with no in-memory state at all.
    private var lastMatchedDistance: Double? {
        get {
            UserDefaults.standard.object(forKey: Keys.lastMatchedDistance) != nil
                ? UserDefaults.standard.double(forKey: Keys.lastMatchedDistance)
                : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Keys.lastMatchedDistance)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.lastMatchedDistance)
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

    private enum Keys {
        static let lastMatchedDistance = "trailTracking.lastMatchedDistance"
    }

    init(container: ModelContainer) {
        self.container = container
        super.init()
        manager.delegate = self
        trackedHikeID = UUID(uuidString: UserDefaults.standard.string(forKey: SettingsKey.lastSelectedHikeID) ?? "")
        // Re-arm on every launch: the system wakes the app specifically so it
        // can call this again and receive the pending event — monitoring
        // doesn't itself persist across process launches.
        if UserDefaults.standard.bool(forKey: SettingsKey.backgroundTrackingEnabled) {
            startIfAuthorized()
        }
    }

    // MARK: Settings toggle

    func setEnabled(_ enabled: Bool) {
        #if os(iOS)
        if enabled {
            switch manager.authorizationStatus {
            case .notDetermined, .authorizedWhenInUse:
                manager.requestAlwaysAuthorization()
            case .authorizedAlways:
                manager.startMonitoringSignificantLocationChanges()
            case .denied, .restricted:
                break
            @unknown default:
                break
            }
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
        #endif
    }

    private func startIfAuthorized() {
        #if os(iOS)
        if manager.authorizationStatus == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        }
        #endif
    }

    // MARK: Selection

    /// Called whenever the app's selected hike changes. Immediately shows the
    /// new trail's shape (no live fix yet) so the widget isn't stale/empty
    /// until the next fix arrives.
    func hikeSelectionChanged(to hike: Hike?) {
        trackedHikeID = hike?.id
        lastMatchedDistance = nil
        lastForegroundPublish = nil

        guard let hike, hike.pointCount > 1 else {
            SharedStore.clear()
            Task { await TrailBasemapRenderer.shared.invalidate() }
            WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
            return
        }
        let snapshot = Self.buildSnapshot(hike: hike, liveFix: nil)
        SharedStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
        refreshBasemaps(for: snapshot)
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
        guard hike.id == trackedHikeID else { return }

        // Leaving the trail takes the wider threshold, rejoining it the normal
        // one, so noise around the follow distance doesn't read as a status
        // change in the first place.
        let wasOnRoute = lastForegroundPublish?.wasOnRoute ?? false
        let threshold = wasOnRoute ? Self.offRouteExitMeters : RouteProfile.followMatchThresholdMeters
        let isOnRoute = (match?.offRouteMeters).map { $0 <= threshold } ?? false

        let now = Date()
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
            updateStoredLiveFix(nil, hike: hike)
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
            hike: hike
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
        guard let match = profile.nearestPoint(to: location.coordinate, near: lastMatchedDistance),
              match.offRouteMeters <= RouteProfile.followMatchThresholdMeters,
              let coordinate = profile.coordinate(atDistance: match.distanceAlongRoute) else {
            updateStoredLiveFix(nil, hike: hike)
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
            hike: hike
        )
    }

    // MARK: Shared write path

    /// Updates just the live-fix portion of the stored snapshot, rebuilding
    /// the whole thing from `hike` first if nothing was stored yet or the
    /// stored snapshot belongs to a different hike.
    private func updateStoredLiveFix(_ fix: SharedTrailSnapshot.LiveFix?, hike: Hike) {
        var snapshot = SharedStore.load()
        let isNewTrail = snapshot?.hikeID != hike.id
        if isNewTrail {
            snapshot = Self.buildSnapshot(hike: hike, liveFix: nil)
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

    private static func buildSnapshot(hike: Hike, liveFix: SharedTrailSnapshot.LiveFix?) -> SharedTrailSnapshot {
        let profile = RouteProfile(route: hike.route)
        return SharedTrailSnapshot(
            hikeID: hike.id,
            title: hike.title,
            tintHex: hike.tintHex,
            totalDistanceMeters: hike.distanceMeters,
            elevationLowMeters: profile.elevationRange?.lowerBound,
            elevationHighMeters: profile.elevationRange?.upperBound,
            polyline: decimate(hike.coordinates.map { (latitude: $0.latitude, longitude: $0.longitude) }),
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
        #if os(iOS)
        Task { @MainActor in
            guard manager.authorizationStatus == .authorizedAlways,
                  UserDefaults.standard.bool(forKey: SettingsKey.backgroundTrackingEnabled) else { return }
            manager.startMonitoringSignificantLocationChanges()
        }
        #endif
    }
}
