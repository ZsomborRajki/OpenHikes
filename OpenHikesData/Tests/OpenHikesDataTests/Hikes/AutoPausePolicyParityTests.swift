//
//  AutoPausePolicyParityTests.swift
//  OpenHikesDataTests
//
//  Holds Auto-Pause's figures for standing still to the recorder's (#1470).
//
//  A silence with no motion answer is called a stop only when the fixes
//  before it showed the hiker standing, because that is when the recorder's
//  distance widens its filter and the fixes stop. So "standing" has to mean
//  what the recorder means by it. `AutoPausePolicy` restates the figures
//  rather than reading them, because `OpenHikesShared` cannot import this
//  package; this is the gate that fails when one moves and the other does
//  not.
//

import OpenHikesData
import OpenHikesShared
import Testing

@Suite("Auto-pause policy parity")
struct AutoPausePolicyParityTests {
    @Test("standing still is one pair of figures in two packages")
    func standingStillMatches() {
        #expect(AutoPausePolicy.standard.settledSeconds == MovementThresholds.stationaryInterval)
        #expect(AutoPausePolicy.standard.settledMeters == MovementThresholds.stationaryNetDisplacement)
    }

    @Test("the fastest walk is one figure in two packages")
    func onFootSpeedMatches() {
        #expect(AutoPausePolicy.standard.maximumOnFootSpeed == MovementThresholds.maximumOnFootSpeed)
    }
}
