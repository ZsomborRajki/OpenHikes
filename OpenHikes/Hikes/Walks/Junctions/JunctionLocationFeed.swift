//
//  JunctionLocationFeed.swift
//  OpenHikes
//
//  The fixes junction warnings are given while a walk follows its trail,
//  with the phone in a pocket as much as in a hand.
//
//  ## Why a feed of its own
//
//  A walk is otherwise fed by two things: the hike screen's follow loop,
//  which stops when the screen does, and significant-location changes, which
//  arrive every five hundred metres or so (`BackgroundTrailTracker`). A
//  warning has to come a hundred and fifty metres before a fork, so neither
//  will do. While the warnings are on and a walk is following, this asks
//  Core Location for what a recording asks for — the same accuracy and
//  distance filter, chosen by ``RecordingEnergyPolicy`` for the conditions it
//  starts in — with background delivery, and the status indicator that comes
//  with it. It stops when the walk pauses or ends, or the switch goes off.
//  *Energy policies in force* in `AGENTS.md` has the cost.
//
//  iOS coalesces the demand of every manager in the process, so beside the
//  hike screen's own manager this costs dispatch, not a second receiver —
//  the argument *Settled decisions* makes for the app's two foreground
//  managers.
//

import CoreLocation
import Foundation

/// One fix, reduced to what the guide reads before it crosses to the main
/// actor.
nonisolated struct JunctionFix: Sendable {
    let coordinate: CLLocationCoordinate2D
    /// The course over ground, when the receiver's is worth reading — see
    /// ``LocationFixPolicy/course(of:)``.
    let course: CLLocationDirection?
}

/// Where junction warnings get their fixes. A seam, so a suite can hand the
/// guide fixes of its own and see whether it asked for any.
@MainActor
protocol JunctionLocationFeeding: AnyObject {
    /// Starts delivering accepted fixes to `deliver`, on the main actor, in
    /// the order they were taken.
    func start(deliver: @escaping @MainActor (JunctionFix) -> Void)
    func stop()
}

/// The feed for a launch that must not reach Core Location: a hosted suite,
/// or a UI test, where a background session would outlive the test.
@MainActor
final class DormantJunctionLocationFeed: JunctionLocationFeeding {
    func start(deliver _: @MainActor (JunctionFix) -> Void) { /* nothing to deliver */ }
    func stop() { /* nothing running */ }
}

#if os(iOS)
/// The feed itself.
@MainActor
final class SystemJunctionLocationFeed: NSObject, JunctionLocationFeeding {
    /// Wider than a recording accepts, because a warning needs to know which
    /// trail the hiker is on rather than where on it to the metre.
    nonisolated static let maximumHorizontalAccuracy: CLLocationAccuracy = 50

    private let manager = CLLocationManager()
    private var deliver: (@MainActor (JunctionFix) -> Void)?
    /// What keeps a When In Use authorization applying once the screen
    /// locks, as the recorder's does — see `HikeRecorder+State.swift`.
    private var backgroundSession: CLBackgroundActivitySession?

    override init() {
        super.init()
        manager.delegate = self
    }

    func start(deliver: @escaping @MainActor (JunctionFix) -> Void) {
        self.deliver = deliver
        let profile = RecordingEnergyPolicy.profile(for: RecordingEnergyPolicy.Conditions(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState
        ))
        manager.activityType = .fitness
        manager.desiredAccuracy = profile.desiredAccuracy
        manager.distanceFilter = profile.distanceFilter
        // For the recorder's reason: an automatic pause does not resume by
        // itself, and a hiker who stopped for a view would walk on unwarned.
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
    }

    func stop() {
        deliver = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    private func receive(_ fixes: [JunctionFix]) {
        guard let deliver else { return }
        for fix in fixes { deliver(fix) }
    }
}

extension SystemJunctionLocationFeed: CLLocationManagerDelegate {
    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations
            .filter { location in
                LocationFixPolicy.accepts(
                    location,
                    maximumAge: LocationFixPolicy.foregroundMaximumAge,
                    maximumHorizontalAccuracy: Self.maximumHorizontalAccuracy
                )
            }
            .map { JunctionFix(coordinate: $0.coordinate, course: LocationFixPolicy.course(of: $0)) }
        guard !fixes.isEmpty else { return }
        onMainActor { [weak self] in self?.receive(fixes) }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError _: any Error) {
        // A failed fix is a missed warning, never a reason to stop: the next
        // one may arrive, and the walk's own feeds say what the failure means.
    }
}
#endif
