//
//  TrailRegionMonitor.swift
//  OpenHikes
//
//  The seam between the arming decision and the system service that answers
//  its proximity half. `CLMonitor` lives behind it — see
//  ``CoreLocationTrailRegionMonitor`` — and a test drives it with a fake.
//
//  A seam for the same reason ``SignificantLocationMonitor`` is one: every
//  interesting path here belongs to a process the app did not start. A
//  relaunch has no in-memory state, so what it does is decided entirely by
//  what the system says about a condition registered by some earlier process,
//  and none of that could be driven from a test against `CLMonitor` directly.
//

import Foundation

/// What the system says about the registered region, reduced to the three
/// answers the arming decision can act on.
///
/// ``unknown`` is not a failure. It is the state a freshly registered
/// condition starts in, and the state a launch sees before CoreLocation has
/// evaluated one — and it arms, like every other thing this gate cannot
/// prove. Only ``outside`` stands monitoring down.
nonisolated enum TrailRegionState: Sendable {
    /// The phone is within the trail's region.
    case inside
    /// The phone is outside it — the one answer that stands monitoring down.
    case outside
    /// No condition registered, or none evaluated yet.
    case unknown
}

/// Registers one region with the system and reports what it says about it.
///
/// One condition, not many: this app follows one trail at a time, and the
/// identifier is the monitor's business rather than the caller's.
nonisolated protocol TrailRegionMonitor: Sendable {
    /// Registers `region` as the condition to watch, replacing whatever was
    /// registered before, or removes it entirely for `nil`.
    ///
    /// A newly registered condition starts at ``TrailRegionState/unknown``
    /// until the system evaluates it, which is why the caller treats a
    /// selection change as *arm until told otherwise*.
    func setRegion(_ region: TrailRegion?) async

    /// The system's current answer, which on a launch is the answer a
    /// *previous* process's registration has been accruing.
    ///
    /// This is the whole reason the gate needs no stored position: the
    /// question "is the phone near the trail right now" is one the system has
    /// already been answering, and asking it costs no location request.
    func currentState() async -> TrailRegionState

    /// Starts delivering changes, including any event pending from the
    /// crossing that relaunched this process.
    ///
    /// - Parameter onChange: called on the main actor, once per event, where
    ///   the arming decision's own state lives. Hopping here rather than at
    ///   the call site is what lets a test await a delivery instead of
    ///   yielding and hoping: when `startObserving`'s caller has been handed
    ///   a state, the decision that turns on it has already been re-taken.
    func startObserving(_ onChange: @escaping @MainActor @Sendable (TrailRegionState) -> Void) async
}
