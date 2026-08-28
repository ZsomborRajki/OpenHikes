//
//  HikeActivityPresenting.swift
//  OpenHikes
//
//  The seam between the app's Live Activity policy and ActivityKit itself.
//
//  It exists for the reason every other injectable dependency here does — the
//  suites must never reach a process-global — but the case is sharper than
//  usual. `ActivityKit` refuses outright in a unit test: the app-hosted bundles
//  run under `xcodebuild test` where `ActivityAuthorizationInfo` reports
//  activities disabled, `Activity.request` throws, and there is no way to make
//  either say otherwise. So a suite that talked to ActivityKit could only ever
//  assert that nothing happened.
//
//  What is worth testing is not ActivityKit — it is *when* the app decides to
//  start one, when it decides an update is worth the system's budget, and when
//  it ends one. All of that lives in `HikeLiveActivityController` above this
//  protocol, and every one of those decisions is observable through a stub.
//

import Foundation
import OpenHikesShared

/// Which walks a takedown applies to.
///
/// Coarser than ``HikeActivityAttributes/Subject`` on purpose, because the
/// paths that need it cannot name the walk they are removing. When
/// `HikeRecorder.cleanUpMissingSession()` runs, the journal it would have read
/// the session identifier from is exactly what turned out not to exist — all
/// the app knows, and all it needs to know, is that no *recording* may be on
/// the Lock Screen.
///
/// Cases alphabetical rather than in precedence order; the precedence rule
/// lives in `HikeLiveActivityController`, not in a declaration order.
enum HikeActivityKind: CaseIterable, Equatable {
    case following
    case recording

    func matches(_ subject: HikeActivityAttributes.Subject?) -> Bool {
        guard let subject else { return false }
        switch self {
        case .following: return !subject.isRecording
        case .recording: return subject.isRecording
        }
    }
}

/// What the controller needs from ActivityKit, and nothing more.
///
/// `@MainActor` rather than an actor: ActivityKit's own surface is designed to
/// be driven from the main actor — `Activity.request` is a synchronous system
/// IPC, and `update`/`end` are `async` and suspend rather than block — and the
/// only state behind this is one handle. See the "types that should not become
/// actors" note in the repository instructions for the shape of the argument.
@MainActor
protocol HikeActivityPresenting: AnyObject {
    /// Whether the system will accept an activity at all: the per-app Live
    /// Activities switch in Settings, which the walker owns and the app only
    /// reads.
    var areActivitiesEnabled: Bool { get }

    /// What the *system* is showing for this app, or `nil` if nothing is.
    ///
    /// Authoritative rather than remembered. A Live Activity outlives the
    /// process that started it, so a fresh launch holds no handle to one that
    /// is nonetheless on the walker's Lock Screen — and an implementation that
    /// answered from its own handle would report `nil` while the panel is
    /// plainly there. `HikeLiveActivityController.activeSubject` is the other
    /// question, "what is *this process* presenting", and the two differ
    /// exactly across a relaunch.
    var activeSubject: HikeActivityAttributes.Subject? { get }

    /// Requests a new activity. Silent on failure: a refusal is the system's
    /// answer about a decoration, and there is nothing for the walker to do
    /// about it in the middle of a hike.
    func start(
        _ attributes: HikeActivityAttributes,
        state: HikeActivityAttributes.ContentState,
        staleAfter: TimeInterval
    ) async

    func update(
        _ state: HikeActivityAttributes.ContentState,
        staleAfter: TimeInterval
    ) async

    /// Ends the running activity, showing `finalState` for as long as
    /// `dismissAfter` allows.
    ///
    /// - Parameter dismissAfter: how long the finished activity stays on the
    ///   Lock Screen. `nil` removes it at once — the right answer for a
    ///   discarded recording, which has no result to show.
    func end(
        finalState: HikeActivityAttributes.ContentState?,
        dismissAfter: TimeInterval?
    ) async

    /// Ends every activity of `kind` the system is showing for this app,
    /// including ones this process never started.
    ///
    /// The rest of this protocol acts through the handle the presenter is
    /// holding, which is the right thing while one walk runs in one process
    /// and is simply absent after a relaunch — so `end(finalState:dismissAfter:)`
    /// against no handle is a silent no-op, and the panel from a killed launch
    /// survived every path that existed to remove it. This one goes to the
    /// system's own list instead.
    ///
    /// No `finalState` and no `dismissAfter` by construction: there is nothing
    /// truthful to leave behind. The figures belong to a walk this process
    /// cannot describe, and every caller has already concluded that the walk
    /// they name is gone.
    func endUnowned(_ kind: HikeActivityKind) async
}
