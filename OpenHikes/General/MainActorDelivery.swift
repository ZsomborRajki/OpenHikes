//
//  MainActorDelivery.swift
//  OpenHikes
//
//  The bridge a `nonisolated` framework callback uses to reach main-actor
//  state without allocating a task for every delivery.
//

import Foundation

/// Runs `body` on the main actor, synchronously when the caller is already
/// there.
///
/// The alternative — `Task { @MainActor in … }` — costs a heap allocation and
/// an actor hop per call, and this app's hottest `nonisolated` callback is a
/// GPS fix arriving at three live `CLLocationManagerDelegate`s at once. It
/// also gives up ordering: two *separate* unstructured tasks on one actor have
/// no defined order between them, so a delegate that sorts a batch by
/// timestamp only guarantees ordering *within* the batch. A pair reordered
/// across batches meets ``RecordingFixPolicy``'s `interval > 0` guard and the
/// older fix is dropped without a trace.
///
/// Both problems are `MainActor.assumeIsolated`'s to solve, and the assumption
/// holds for the callers here: every `CLLocationManager` in this app is created
/// on the main actor — the targets build with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — and Core Location delivers to
/// the run loop of the thread its manager was created on.
///
/// The fallback is not defensive clutter. "Already on the main thread" is a
/// guarantee about Core Location's own deliveries, not about every possible
/// caller, and `assumeIsolated` answers a wrong guess with a trap. A fix that
/// arrives late is worth more than a crash.
@inline(__always)
nonisolated func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}
