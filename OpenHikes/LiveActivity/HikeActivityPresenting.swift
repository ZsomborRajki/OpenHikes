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

    /// What is on screen right now, or `nil` if nothing is.
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
}
