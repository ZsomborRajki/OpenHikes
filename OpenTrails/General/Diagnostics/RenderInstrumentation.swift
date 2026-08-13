//
//  RenderInstrumentation.swift
//  OpenTrails
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

#if DEBUG
@MainActor
enum RenderSignpost {
    private static let signposter = OSSignposter(subsystem: "OpenTrails", category: "Rendering")
    private static let logger = Logger(subsystem: "OpenTrails", category: "Rendering")

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
    private static var callCounts: [String: Int] = [:]
    private static var lastFireTimes: [String: ContinuousClock.Instant] = [:]

    /// A single point-in-time marker — e.g. "a body evaluated" or "an update
    /// call ran". `detail` should say what happened (or didn't) so the
    /// Points of Interest track (or console line) reads like a log, not just
    /// unlabeled dots — e.g. `.mark("MapUpdate", "tile=skip center=skip route=rebuild")`.
    static func mark(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        let resolvedDetail = detail()
        signposter.emitEvent(name, "\(resolvedDetail, privacy: .public)")
        guard consoleLoggingEnabled else { return }
        logToConsole(name: "\(name)", detail: resolvedDetail)
    }

    /// Brackets a span of work so its duration shows as a bar (not just a
    /// point) on the Points of Interest track. Use where the *cost* of a call
    /// matters, not just its frequency (e.g. tile draw, route rebuild).
    static func interval<T>(_ name: StaticString, _ body: () -> T) -> T {
        let state = signposter.beginInterval(name)
        let start = consoleLoggingEnabled ? ContinuousClock.now : nil
        defer {
            signposter.endInterval(name, state)
            if let start {
                let elapsed = ContinuousClock.now - start
                logToConsole(
                    name: "\(name)",
                    detail: elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 2)))
                )
            }
        }
        return body()
    }

    private static func logToConsole(name: String, detail: String) {
        let now = ContinuousClock.now
        let count = (callCounts[name] ?? 0) + 1
        callCounts[name] = count
        let gap = lastFireTimes[name]
            .map { "+" + (now - $0).formatted(.units(allowed: [.milliseconds], fractionalPart: .hide)) } ?? "first"
        lastFireTimes[name] = now
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        logger.debug(
            "[RenderSignpost] \(name, privacy: .public) #\(count) \(gap, privacy: .public)\(suffix, privacy: .public)"
        )
    }
}
#else
@MainActor
enum RenderSignpost {
    @inline(__always)
    static func mark(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        // no-op in release builds
    }

    @inline(__always)
    static func interval<T>(_ name: StaticString, _ body: () -> T) -> T { body() }
}
#endif
