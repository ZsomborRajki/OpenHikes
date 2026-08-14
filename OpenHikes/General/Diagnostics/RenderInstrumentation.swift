//
//  RenderInstrumentation.swift
//  OpenHikes
//
//  Debug-only instrumentation for finding unnecessary SwiftUI body
//  re-evaluations and UIViewRepresentable update calls — with no on-screen
//  footprint and no steady-state cost of its own (unlike a debug HUD, it
//  can't skew the very thing it's measuring).
//
//  Two ways to look at it:
//
//  1. Instruments, on a real device: Product ▸ Profile (⌘I) ▸ a "Blank"
//     template with the "os_signpost" (or "Points of Interest") instrument
//     added manually — filter by name to see how often a view's body
//     actually runs, or how often an imperative update call did real work
//     vs. no-op'd on an unchanged guard. (Xcode's built-in "SwiftUI"
//     template additionally decodes view-identity/body info but is
//     device-only — it won't attach to the Simulator at all.)
//
//  2. The Xcode console, in the Simulator: set the `RENDER_SIGNPOST_LOG=1`
//     environment variable on the run scheme and every mark/interval also
//     prints a console line with a running per-name call count and the time
//     since that name last fired. This is what you want when testing
//     location-driven UI (e.g. auto-follow) — Simulator location spoofing
//     (Debug ▸ Simulate Location, or a GPX in the scheme's Options tab) is
//     far more convenient than walking around with a device, and this path
//     needs nothing but a normal debug run, no separate Instruments session.
//
//  3. A UI test, headless: launch the app with
//     `--ui-test-performance-log=<scenario>` and every mark, interval and
//     main-thread stall is appended to a tab-separated file in the app
//     container — see ``PerformanceLog``. This is path 2 without a human
//     reading a console, which is what lets `PerformanceUITests` assert a
//     render budget instead of merely reporting one.
//
//  For the battery question specifically, prefer path 1 with the "Energy
//  Log" template during an actual walk with the app foregrounded, then
//  correlate energy spikes against the marks here — e.g. does
//  `MapUpdateCalled` firing every second (driven by the throttled location
//  publish) actually cost anything, or does every sub-step report "skip"
//  and it's free? Let what's measured decide what's worth optimizing next,
//  rather than guessing.
//
//  No-ops entirely in release builds.
//

import Foundation
import os
import Synchronization

#if DEBUG
/// `nonisolated` because pipeline work worth timing does not all happen on the
/// main actor — tile decode, GPX parsing and trail matching are deliberately
/// off it, and an instrument that could only be called from the main thread
/// would be unable to measure exactly the work that was moved away from it.
/// The console tally below is therefore held under a lock rather than by actor
/// isolation.
nonisolated enum RenderSignpost {
    private static let signposter = OSSignposter(subsystem: "OpenHikes", category: "Rendering")
    private static let logger = Logger(subsystem: "OpenHikes", category: "Rendering")

    /// An open span. `start` is `nil` when nothing is collecting durations, so
    /// an unmeasured run does not even read the clock.
    struct IntervalState {
        let signpost: OSSignpostIntervalState
        let start: ContinuousClock.Instant?
    }

    /// Echoes every mark/interval to the console in addition to emitting the
    /// signpost, so activity is visible during a plain debug run — no
    /// Instruments session (and so no Simulator restriction) required. Flip
    /// on via the scheme's Run ▸ Arguments ▸ Environment Variables.
    private static let consoleLoggingEnabled = ProcessInfo.processInfo.environment["RENDER_SIGNPOST_LOG"] == "1"

    /// Per-name call count and last-fire time, purely for the console path —
    /// gives each printed line a running tally and a time-since-last-fire
    /// gap, which is what actually shows "this is re-rendering way more
    /// than expected" without needing Instruments' timeline view.
    ///
    /// Timed on `ContinuousClock` rather than `CFAbsoluteTimeGetCurrent`: the
    /// latter is wall-clock, so an NTP correction mid-run can make an interval
    /// come out negative and a gap read as time travel.
    ///
    /// Under one `Mutex` rather than two, so a name's count and its gap always
    /// come from the same instant even when two threads mark at once.
    private struct ConsoleTally {
        var callCounts: [String: Int] = [:]
        var lastFireTimes: [String: ContinuousClock.Instant] = [:]
    }

    private static let consoleTally = Mutex(ConsoleTally())

    /// A single point-in-time marker — e.g. "a body evaluated" or "an update
    /// call ran". `detail` should say what happened (or didn't) so the
    /// Points of Interest track (or console line) reads like a log, not just
    /// unlabeled dots — e.g. `.mark("MapUpdate", "tile=skip center=skip route=rebuild")`.
    static func mark(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        let resolvedDetail = detail()
        signposter.emitEvent(name, "\(resolvedDetail, privacy: .public)")
        PerformanceLog.shared?.record(
            kind: .mark,
            name: "\(name)",
            detail: resolvedDetail
        )
        guard consoleLoggingEnabled else { return }
        logToConsole(name: "\(name)", detail: resolvedDetail)
    }

    /// Brackets a span of work so its duration shows as a bar (not just a
    /// point) on the Points of Interest track. Use where the *cost* of a call
    /// matters, not just its frequency (e.g. tile draw, route rebuild).
    ///
    /// Typed-throws rather than plain `rethrows` so it can wrap the app's
    /// `throws(ImportFailure)`-style pipeline entry points without widening
    /// their error type to `any Error` at the call site.
    static func interval<T, E: Error>(
        _ name: StaticString,
        _ body: () throws(E) -> T
    ) throws(E) -> T {
        let state = beginInterval(name)
        defer { endInterval(name, state) }
        return try body()
    }

    /// The two halves of ``interval(_:_:)`` for the calls a closure cannot
    /// wrap — an `async` span, or one whose body mutates a local the enclosing
    /// scope goes on to use.
    static func beginInterval(_ name: StaticString) -> IntervalState {
        let measuring = consoleLoggingEnabled || PerformanceLog.shared != nil
        return IntervalState(
            signpost: signposter.beginInterval(name),
            start: measuring ? ContinuousClock.now : nil
        )
    }

    static func endInterval(_ name: StaticString, _ state: IntervalState) {
        signposter.endInterval(name, state.signpost)
        guard let start = state.start else { return }
        let elapsed = ContinuousClock.now - start
        PerformanceLog.shared?.record(
            kind: .interval,
            name: "\(name)",
            value: Self.milliseconds(elapsed)
        )
        guard consoleLoggingEnabled else { return }
        logToConsole(
            name: "\(name)",
            detail: elapsed.formatted(
                .units(allowed: [.milliseconds], fractionalPart: .show(length: 2))
            )
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let attosecondsPerMillisecond = 1e15
        let millisecondsPerSecond = 1000.0
        return Double(duration.components.seconds) * millisecondsPerSecond
            + Double(duration.components.attoseconds) / attosecondsPerMillisecond
    }

    private static func logToConsole(name: String, detail: String) {
        let now = ContinuousClock.now
        let (count, previous) = consoleTally.withLock { tally -> (Int, ContinuousClock.Instant?) in
            let count = (tally.callCounts[name] ?? 0) + 1
            tally.callCounts[name] = count
            let previous = tally.lastFireTimes[name]
            tally.lastFireTimes[name] = now
            return (count, previous)
        }
        let gap = previous
            .map { "+" + (now - $0).formatted(.units(allowed: [.milliseconds], fractionalPart: .hide)) } ?? "first"
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        logger.debug(
            "[RenderSignpost] \(name, privacy: .public) #\(count) \(gap, privacy: .public)\(suffix, privacy: .public)"
        )
    }
}
#else
nonisolated enum RenderSignpost {
    struct IntervalState {}

    @inline(__always)
    static func mark(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        // no-op in release builds
    }

    @inline(__always)
    static func interval<T, E: Error>(
        _ name: StaticString,
        _ body: () throws(E) -> T
    ) throws(E) -> T {
        try body()
    }

    @inline(__always)
    static func beginInterval(_ name: StaticString) -> IntervalState { IntervalState() }

    @inline(__always)
    static func endInterval(_ name: StaticString, _ state: IntervalState) {
        // no-op in release builds
    }
}
#endif
