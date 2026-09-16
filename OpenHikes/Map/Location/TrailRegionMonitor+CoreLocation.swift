//
//  TrailRegionMonitor+CoreLocation.swift
//  OpenHikes
//
//  `CLMonitor` as the tracker's region monitor.
//
//  An actor rather than a class with a lock: CoreLocation documents that only
//  one `CLMonitor` with a given name may be open at a time, so the cached
//  instance below is the kind of state two callers must not race on. The name
//  is fixed and the conditions persist under it, which is what lets a process
//  the system started ask about a region an earlier one registered.
//
//  That "only one at a time" is enforced by a thrown `NSException`, not by the
//  `false` return the Objective-C header describes — and an ObjC exception is
//  not catchable from Swift, so a second open terminates the process. Hence
//  ``SystemTrailRegionMonitor/shared``: the one-per-name rule is a
//  one-per-process rule here, and this app builds a tracker in four places.
//

import CoreLocation
import Foundation
import os

/// The one region monitor a process may have.
///
/// A singleton for a reason that is not convenience: opening a second
/// `CLMonitor` under a name already in use throws an Objective-C exception,
/// which Swift cannot catch and which therefore takes the app down. Previews,
/// a hosted test bundle and the app itself all build
/// ``BackgroundTrailTracker``, so "there will only ever be one tracker" is not
/// a guarantee this code can make — and it is the kind of assumption that
/// holds until the day someone adds a fifth call site.
///
/// Dormant when the launch is not using live location, on the same argument
/// ``DormantLocationSource`` makes: a hosted test run must not register real
/// geofences on the machine it is running on.
nonisolated enum SystemTrailRegionMonitor {
    static let shared: any TrailRegionMonitor = AppLaunchEnvironment.usesLiveLocation
        ? CoreLocationTrailRegionMonitor()
        : DormantTrailRegionMonitor()
}

actor CoreLocationTrailRegionMonitor: TrailRegionMonitor {
    /// The conditions are stored by the system under this name. Fixed, and
    /// not to be changed lightly: a different name is a different, empty set
    /// of conditions, and the ones registered under the old name are left
    /// behind with no monitor configured to receive their events.
    private static let monitorName = "OpenHikesTrailProximity"
    /// The one condition. A constant rather than the hike's id, because the
    /// region is replaced on every selection and a per-hike identifier would
    /// leave the previous trail's condition registered behind it.
    private static let conditionIdentifier = "trackedTrail"

    private static let log = Logger(subsystem: "com.tappium.OpenHikes", category: "TrailRegion")

    private var monitor: CLMonitor?
    private var eventLoop: Task<Void, Never>?
    /// Where events go. Replaceable, and read per event rather than captured
    /// by the loop: the loop outlives any one tracker, and a tracker being
    /// torn down should stop hearing about crossings the moment its
    /// replacement starts.
    private var onChange: (@MainActor @Sendable (TrailRegionState) -> Void)?

    deinit { eventLoop?.cancel() }

    func setRegion(_ region: TrailRegion?) async {
        let opened = await openMonitor()
        // Unconditionally, including when nothing is registered: removing an
        // identifier the monitor does not hold is a no-op, and checking first
        // would be two round trips to answer a question we do not act on.
        await opened.remove(Self.conditionIdentifier)
        guard let region else { return }
        await opened.add(
            CLMonitor.CircularGeographicCondition(center: region.center, radius: region.radiusMeters),
            identifier: Self.conditionIdentifier
        )
    }

    func currentState() async -> TrailRegionState {
        let opened = await openMonitor()
        guard let record = await opened.record(for: Self.conditionIdentifier) else { return .unknown }
        return TrailRegionState(record.lastEvent.state)
    }

    func startObserving(_ onChange: @escaping @MainActor @Sendable (TrailRegionState) -> Void) async {
        self.onChange = onChange
        // One loop per process, whoever is listening to it.
        guard eventLoop == nil else { return }
        let opened = await openMonitor()
        eventLoop = Task { [weak self] in
            do {
                for try await event in await opened.events {
                    guard event.identifier == Self.conditionIdentifier else { continue }
                    await self?.deliver(TrailRegionState(event.state))
                }
            } catch {
                // The sequence ends when the monitor goes away, which on this
                // app's one long-lived monitor means the process is going too.
                // Nothing here can usefully retry, and the arming decision's
                // own fail-open rule is what covers a feed that has stopped.
                Self.log.error("Trail region events ended: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Hands a crossing to whoever is currently listening.
    private func deliver(_ state: TrailRegionState) async {
        await onChange?(state)
    }

    /// The one open monitor, created on first use.
    ///
    /// Opening it is what makes any event pending from the crossing that
    /// relaunched this process deliverable — CoreLocation stops monitoring
    /// conditions whose events nothing is configured to receive.
    private func openMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let opened = await CLMonitor(Self.monitorName)
        monitor = opened
        return opened
    }
}

nonisolated private extension TrailRegionState {
    /// `unmonitored` joins `unknown` rather than `outside`: a condition the
    /// system has stopped watching says nothing about where the phone is, and
    /// this gate arms on everything it cannot prove.
    init(_ state: CLMonitor.Event.State) {
        switch state {
        case .satisfied: self = .inside
        case .unsatisfied: self = .outside
        default: self = .unknown
        }
    }
}
