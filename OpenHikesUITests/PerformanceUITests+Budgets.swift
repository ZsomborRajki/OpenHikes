//
//  PerformanceUITests+Budgets.swift
//  OpenHikesUITests
//
//  How a budget is stated, and what a violated one says.
//
//  Kept apart from the scenarios because these four are the whole vocabulary
//  the suite has: a ceiling, a floor, a per-fix ratio, and a stall. A new
//  scenario should be expressible in them, and a scenario that needs a fifth
//  is usually measuring something it has not finished thinking about.
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
}
