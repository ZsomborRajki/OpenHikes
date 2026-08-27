//
//  SettleSupport.swift
//  OpenHikesTests
//
//  One place to wait for the `Task { @MainActor in … }` hop that every
//  `nonisolated` delegate callback in this app makes.
//
//  Each suite that needed such a wait used to spin its own fixed number of
//  `Task.yield()`s — 8 here, 32 there. That premise is wrong in a way that
//  only shows up under load: a yield hands the executor to whichever job is
//  next, not to this test's hop, so "8 turns" buys an amount of progress that
//  depends entirely on how busy the machine is. On a developer's machine it
//  passed. On CI it did not — `Map coordinator` and `Location publishing`
//  both failed in run 31834514456 with a `hasCentered` that was still false
//  and a `routeFix` that was still nil, in tests that had by then been running
//  for 34 and 42 seconds without touching disk or network.
//
//  So wait for the effect rather than for a number of scheduler turns. A
//  caller names what it is waiting for, and the budget is a real deadline —
//  which turns a timeout into "waited 5s for X" instead of a bare failed
//  expectation further down.
//
//  A deadline is only meaningful if the test owns the machine while it runs,
//  and that is why `OpenHikes.xctestplan` marks both unit bundles
//  `parallelizable: false`. The bundle is main-actor isolated project-wide
//  (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so Swift Testing's
//  in-process parallelism could never run two tests at once anyway — it could
//  only interleave a thousand of them at their suspension points, all
//  contending for one executor. Run 33049137656 is what that costs: seven
//  recording tests started within two seconds of each other, and the first
//  five-second budget took *seventeen* seconds of wall time to notice it had
//  expired, because a 5 ms poll was not resumed for seconds at a time. Do not
//  reach for a bigger number here if this file starts failing again; check
//  that the plan still serializes first.
//

import Foundation
import Testing

/// How long a settle waits for its condition before recording a failure.
///
/// Generous on purpose. It is only ever paid by a test that is going to fail
/// anyway — a satisfied condition returns on the first check — so the cost of
/// being wrong here is a slow failure, while the cost of being too tight is
/// the flake this file exists to remove.
private let settleBudget = Duration.seconds(5)

/// How long to wait between checks once the fast path hasn't settled.
private let settlePollInterval = Duration.milliseconds(5)

/// Round trips to make when no condition is given.
///
/// One drains everything already enqueued. More than one is for the chains:
/// `LocationFixStreamTests` waits on a delegate hop that wakes an Observation
/// continuation that wakes a consumer task, and each of those steps can only
/// be enqueued once the step before it has run.
private let settleRoundTrips = 8

/// One trip through the main actor's own queue. An unstructured task enqueued
/// here sits behind anything a delegate callback enqueued before it, so by the
/// time this one runs, those have run.
@MainActor
private func mainActorRoundTrip() async {
    await Task { @MainActor in
        // Being scheduled at all is the point; there is nothing to do.
    }.value
}

/// One poll interval of a deadline loop. `false` means the task was cancelled
/// and the caller should stop.
///
/// Shared so that a suite hand-rolling its own wait — which
/// `HikeRecorderTests+Sensors.swift` has to, because reading an actor's
/// contents needs an `await` and a settle condition is synchronous — spells
/// the sleep the same way this file does. `try? await Task.sleep` is the
/// version to avoid: once the task is cancelled, sleeping throws immediately,
/// so swallowing the error turns the loop into a tight spin that holds the
/// main actor until the deadline passes.
@MainActor
func settlePollTick() async -> Bool {
    do {
        try await Task.sleep(for: settlePollInterval)
        return true
    } catch {
        return false
    }
}

/// Lets the `Task { @MainActor in … }` hop that every delegate callback in
/// this app makes actually run, and — when `condition` is given — keeps
/// waiting until the effect of that hop is visible.
///
/// Always pass `condition` when the test has an observable effect to name.
/// Without one this still orders itself after anything already enqueued on the
/// main actor, and unwinds a few steps of chained enqueues, but it is a fixed
/// amount of progress again and it has nothing to report when that wasn't
/// enough. A named condition is the only version of this that is insensitive
/// to how loaded the machine is.
///
/// - Parameters:
///   - description: Named in the failure if the condition never holds.
///   - condition: The effect being waited for, evaluated on the main actor.
@MainActor
func settleDelegateHop(
    until description: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: (@MainActor () -> Bool)? = nil
) async {
    guard let condition else {
        for _ in 0..<settleRoundTrips { await mainActorRoundTrip() }
        return
    }

    await mainActorRoundTrip()
    if condition() { return }

    let deadline = ContinuousClock.now + settleBudget
    while ContinuousClock.now < deadline {
        guard await settlePollTick() else {
            // Cancelled — a `.timeLimit` fired, or the run is being torn down.
            // Give the condition one last look before leaving.
            if !condition() {
                Issue.record(
                    Comment(rawValue: """
                        Cancelled while waiting for \
                        \(description?.rawValue ?? "the main-actor delegate hop to settle").
                        """),
                    sourceLocation: sourceLocation
                )
            }
            return
        }
        if condition() { return }
    }

    Issue.record(
        Comment(rawValue: """
            Timed out after \(settleBudget) waiting for \
            \(description?.rawValue ?? "the main-actor delegate hop to settle").
            """),
        sourceLocation: sourceLocation
    )
}
