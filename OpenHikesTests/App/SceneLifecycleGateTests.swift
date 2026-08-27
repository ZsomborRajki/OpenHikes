//
//  SceneLifecycleGateTests.swift
//  OpenHikesTests
//

import SwiftUI
import Testing

@testable import OpenHikes

@MainActor
@Suite("Scene lifecycle gate")
struct SceneLifecycleGateTests {
    /// The sequence iOS actually delivers for a backgrounding and a return.
    private static let roundTrip: [ScenePhase] = [
        .inactive, .background, .inactive, .active
    ]

    @Test("leaving the foreground resigns at .inactive, before .background")
    func resignsAtInactiveOnTheWayOut() {
        var gate = SceneLifecycleGate()
        #expect(gate.event(for: .inactive) == .willResignActive)
    }

    /// `.background` is the last point a measured run can count on — UI
    /// automation backgrounds the app and only then terminates it — so it has
    /// to resign in its own right rather than being folded into the
    /// `.inactive` that preceded it.
    @Test(".background resigns even though .inactive already did")
    func resignsAgainAtBackground() {
        var gate = SceneLifecycleGate()
        _ = gate.event(for: .inactive)
        #expect(gate.event(for: .background) == .willResignActive)
    }

    @Test("the .inactive step of returning is redundant")
    func returningInactiveIsDropped() {
        var gate = SceneLifecycleGate()
        _ = gate.event(for: .inactive)
        _ = gate.event(for: .background)
        #expect(gate.event(for: .inactive) == .redundant)
    }

    @Test("a full round trip resigns twice and becomes active once")
    func roundTripProducesExactlyThreeEffects() {
        var gate = SceneLifecycleGate()
        let events = Self.roundTrip.map { gate.event(for: $0) }
        #expect(
            events == [.willResignActive, .willResignActive, .redundant, .becameActive]
        )
    }

    /// Pulling Control Center or taking a call never reaches `.background`, so
    /// the app returns through an `.inactive` that has to keep resigning —
    /// the gate must not confuse "seen an `.inactive` already" with "been
    /// backgrounded".
    @Test("a transient interruption that never backgrounds still resigns")
    func transientInactiveAlwaysResigns() {
        var gate = SceneLifecycleGate()
        #expect(gate.event(for: .inactive) == .willResignActive)
        #expect(gate.event(for: .active) == .becameActive)
        #expect(gate.event(for: .inactive) == .willResignActive)
    }

    /// Two backgroundings in a row must each get their own resign; the flag
    /// is cleared by `.active` and by nothing else.
    @Test("a second round trip resigns as many times as the first")
    func gateResetsBetweenEpisodes() {
        var gate = SceneLifecycleGate()
        let first = Self.roundTrip.map { gate.event(for: $0) }
        let second = Self.roundTrip.map { gate.event(for: $0) }
        #expect(first == second)
        #expect(first.filter { $0 == .willResignActive }.count == 2)
    }

    /// Without this the gate would have to be primed by an `.active` before it
    /// answered correctly, and the very first phase a scene reports is not
    /// guaranteed to be one.
    @Test("a gate that has never seen .active still resigns")
    func freshGateResignsBeforeAnyActive() {
        var gate = SceneLifecycleGate()
        #expect(gate.event(for: .background) == .willResignActive)
        #expect(gate.event(for: .inactive) == .redundant)
    }
}
