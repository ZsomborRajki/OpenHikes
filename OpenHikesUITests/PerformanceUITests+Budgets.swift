//
//  PerformanceUITests+Budgets.swift
//  OpenHikesUITests
//
//  How a budget is stated, and what a violated one says.
//
//  Kept apart from the scenarios because these six are the whole vocabulary
//  the suite has: a ceiling, a floor, a per-fix ratio, a stall count inside a
//  phase, a stall count across a whole run, and a worst-case stall length. A
//  new scenario should be expressible in them, and one that needs a seventh is
//  usually measuring something it has not finished thinking about.
//
//  Five of the six are scoped to a phase, which is the shape that makes them
//  comparable across machines — and it is also a blind spot, because a run is
//  mostly not inside a phase. ``assertStalls(atMost:in:scenario:)`` is the one
//  that covers the gaps.
//

import XCTest

extension PerformanceUITests {

    /// The counterpart to `assertNoMoreThan`: proof that the gesture reached
    /// the app at all. Without it a phase that silently failed to touch
    /// anything would satisfy every budget above it by doing nothing.
    func assertAtLeast(
        _ minimum: Double,
        of name: String,
        in delta: PerformanceCounterDelta,
        phase: String
    ) {
        let observed = delta.count(of: name)
        XCTAssertGreaterThanOrEqual(
            observed,
            minimum,
            "\(name) ran \(observed) times during \(phase); the gesture may not have landed"
        )
    }

    func assertNoMoreThan(
        _ limit: Double,
        of name: String,
        in delta: PerformanceCounterDelta,
        phase: String
    ) {
        let observed = delta.count(of: name)
        XCTAssertLessThanOrEqual(
            observed,
            limit,
            "\(name) ran \(observed) times during \(phase), budget \(limit)"
        )
    }

    func assertRatio(
        atMost limit: Double,
        of name: String,
        per events: Double,
        in delta: PerformanceCounterDelta
    ) {
        guard events > 0 else { return }
        let ratio = delta.count(of: name) / events
        XCTAssertLessThanOrEqual(
            ratio,
            limit,
            "\(name) ran \(ratio) times per accepted fix, budget \(limit)"
        )
    }

    func assertNoStall(in delta: PerformanceCounterDelta, phase: String) {
        let stalls = delta.count(of: "MainThread")
        XCTAssertEqual(
            stalls,
            0,
            "the main thread stalled \(stalls) times during \(phase)"
        )
    }

    /// A ceiling on how many times the main thread stalled across the *whole*
    /// scenario, measured phase or not.
    ///
    /// ``assertNoStall(in:phase:)`` is scoped to a phase, and a scenario is
    /// mostly not in one: the navigation that reaches a screen, the wait for a
    /// search to fill a grid, and the backgrounding that ends every run all sit
    /// between phases. Every stall this suite has recorded after launch landed
    /// in one of those gaps — 203–207 ms pushing Settings, 218–222 ms starting
    /// a recording, 216–372 ms backgrounding the photo-discovery sheet — and
    /// the per-phase budgets counted zero for all of them while the suite
    /// reported 10/10 green. A budget stated per phase can only ever see the
    /// moments somebody already thought to bracket.
    ///
    /// Absolute rather than a delta, like ``assertLaunchStall(atMost:in:)`` and
    /// for the same reason: the point is to cover the parts of the run no
    /// reading brackets, and launch is the first of them. Every scenario
    /// therefore carries one stall it did not do anything to earn — the launch
    /// stall, whose *length* is what ``assertLaunchStall(atMost:in:)`` bounds —
    /// so a budget of one means "nothing beyond launch", and anything above
    /// that is a stall a scenario is knowingly carrying and should name.
    func assertStalls(
        atMost limit: Double,
        in counters: PerformanceCounters,
        scenario: String
    ) {
        let stalls = counters.value(of: "MainThread")
        XCTAssertLessThanOrEqual(
            stalls,
            limit,
            "the main thread stalled \(stalls) times across \(scenario), budget \(limit) — "
                + "the worst was \(counters.maximum(of: "MainThread")) ms; "
                + "the scenario's event file says which gap it landed in"
        )
    }

    /// A ceiling on the worst main-thread stall the launch produced.
    ///
    /// The one budget that is a duration rather than a count, so it is worth
    /// saying why it earned its place. Every other budget is a count taken
    /// across a phase, and launch has no phase: it is over
    /// before the first counter is read, which is exactly why the ~600 ms
    /// stall the watchdog has recorded in every run since this suite existed
    /// went un-asserted while being the largest single cost in the document.
    ///
    /// Milliseconds rather than a count, because the count is always one and
    /// the number that matters is how long. Set well above what the app does
    /// today for the reason every threshold here is: an old device, a cold
    /// simulator and a busy machine all move this, and a test that fails on a
    /// loaded laptop is a test that gets deleted.
    func assertLaunchStall(
        atMost milliseconds: Double,
        in counters: PerformanceCounters
    ) {
        let worst = counters.maximum(of: "MainThread")
        XCTAssertLessThanOrEqual(
            worst,
            milliseconds,
            "the longest main-thread stall was \(worst) ms, ceiling \(milliseconds) ms — "
                + "launch is blocking longer than it used to"
        )
    }
}
