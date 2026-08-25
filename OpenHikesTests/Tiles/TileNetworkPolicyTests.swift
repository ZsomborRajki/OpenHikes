//
//  TileNetworkPolicyTests.swift
//  OpenHikesTests
//
//  The offline-first claim, expressed as assertions.
//
//  A tile fetched is a radio switched on, and on a hike the radio is the
//  second-largest energy cost after the GPS. What makes this worth a test
//  rather than a code review is that the failure is invisible in both
//  directions: too permissive and the app quietly spends a cellular allowance
//  and a battery on tiles it had every reason not to fetch; too strict and the
//  map goes blank in the one place a hiker actually needs it.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile network policy")
struct TileNetworkPolicyTests {
    private func decide(
        _ purpose: TileFetchPurpose,
        online: Bool = true,
        expensive: Bool = false,
        constrained: Bool = false,
        power: PowerState = PowerState()
    ) -> TileNetworkDecision {
        TileNetworkPolicy.decide(
            purpose,
            conditions: TileNetworkConditions(
                isOnline: online,
                isExpensive: expensive,
                isConstrained: constrained
            ),
            power: power
        )
    }

    @Test("Wi-Fi with nothing objecting allows both kinds of fetch")
    func nominalAllowsEverything() {
        #expect(decide(.interactive) == .allowed)
        #expect(decide(.speculative) == .allowed)
    }

    @Test("Offline denies everything")
    func offlineDeniesEverything() {
        #expect(decide(.interactive, online: false) == .denied("offline"))
        #expect(decide(.speculative, online: false) == .denied("offline"))
    }

    /// Not gated on any app setting, deliberately — there are no networking
    /// settings at all. Low Data Mode is a per-network instruction the user
    /// gave the system, and a map tile is optional by construction: there is
    /// either a cached one or a blank square, and neither is worth overriding
    /// them for.
    @Test("Low Data Mode denies everything, with no setting to override it")
    func constrainedDeniesEverything() {
        #expect(decide(.interactive, constrained: true) == .denied("low-data-mode"))
        #expect(decide(.speculative, constrained: true) == .denied("low-data-mode"))
    }

    /// The asymmetry the removal of the cellular toggle rests on. A walker on
    /// a metered connection is looking at the map now, so the tile under their
    /// thumb loads; what a metered connection costs them is the reading ahead.
    @Test("Cellular keeps the map drawing and never carries speculative traffic")
    func cellularCarriesInteractiveTrafficOnly() {
        #expect(decide(.interactive, expensive: true) == .allowed)
        #expect(
            decide(.speculative, expensive: true) == .denied("cellular-speculative")
        )
    }

    /// The rule that keeps a battery mitigation from turning into a blank
    /// map: Low Power Mode stops the app reading ahead, and does not stop it
    /// drawing what the walker is looking at.
    @Test("Low Power Mode stops reading ahead but never blanks the map")
    func lowPowerModeStopsSpeculativeTrafficOnly() {
        let power = PowerState(isLowPowerModeEnabled: true)

        #expect(decide(.interactive, power: power) == .allowed)
        #expect(decide(.speculative, power: power) == .denied("low-power-mode"))
    }

    @Test(
        "Thermal pressure stops reading ahead from serious upward",
        arguments: [
            (ProcessInfo.ThermalState.nominal, true),
            (.fair, true),
            (.serious, false),
            (.critical, false),
        ]
    )
    func thermalStopsSpeculativeTraffic(
        state: ProcessInfo.ThermalState,
        allowed: Bool
    ) {
        let power = PowerState(thermalState: state)

        #expect(decide(.interactive, power: power) == .allowed)
        #expect(decide(.speculative, power: power).isAllowed == allowed)
    }

    /// Every denial has to name itself: a suppressed fetch that logged nothing
    /// is a tile that silently never loads, which is the hardest failure in
    /// this pipeline to diagnose and the one this policy deliberately creates.
    @Test("Every denial carries a reason")
    func denialsAreAttributable() {
        let denials = [
            decide(.interactive, online: false),
            decide(.interactive, constrained: true),
            decide(.speculative, power: PowerState(isLowPowerModeEnabled: true)),
            decide(.speculative, power: PowerState(thermalState: .critical)),
            decide(.speculative, expensive: true),
        ]

        for denial in denials {
            #expect(denial.isAllowed == false)
            #expect(denial.reason?.isEmpty == false)
        }
    }
}
