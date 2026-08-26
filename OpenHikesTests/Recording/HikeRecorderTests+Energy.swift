//
//  HikeRecorderTests+Energy.swift
//  OpenHikesTests
//
//  That the recorder actually reconfigures the GPS, as opposed to computing a
//  profile and filing it.
//
//  ``RecordingEnergyPolicyTests`` pins what the answer should be; these pin
//  that the answer reaches CoreLocation, at the moments it has to. The failure
//  these exist to catch is silent in the worst way: the policy keeps returning
//  the right profile, the recording screen keeps saying the app is conserving,
//  and the GPS keeps running flat out because nobody pushed the value.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

extension HikeRecorderTests {
    @Test("A session starts at the profile the conditions call for")
    func startAppliesTheCurrentProfile() async throws {
        let monitor = PowerStateMonitor(
            read: { PowerState(isLowPowerModeEnabled: true) },
            observesNotifications: false
        )
        let hikeRecorder = makeRecorder(powerMonitor: monitor)

        await hikeRecorder.start()

        let applied = try #require(source.currentProfile)
        #expect(applied.desiredAccuracy == RecordingEnergyPolicy.conservingAccuracy)
        #expect(hikeRecorder.energyProfile == applied)
        #expect(
            hikeRecorder.energyProfile.reason != nil,
            "the recording screen has nothing to show the walker otherwise"
        )
    }

    @Test("A hike begun at full charge stays precise")
    func nominalSessionStaysPrecise() async {
        let hikeRecorder = makeRecorder()

        await hikeRecorder.start()

        #expect(source.currentProfile == .precise)
        #expect(hikeRecorder.energyProfile == .precise)
    }

    /// The transition that has no fix to prompt it. A walker who stops for
    /// lunch and whose battery drops into Low Power Mode while they eat
    /// produces no location updates at all, so a recorder that only
    /// re-evaluated on an accepted fix would keep the GPS at full accuracy for
    /// exactly as long as the walker was doing nothing to interrupt it.
    @Test("Low Power Mode arriving mid-hike reconfigures without a fix")
    func powerStateChangeAppliesWithoutAFix() async {
        let reading = Mutex(PowerState())
        let monitor = PowerStateMonitor(
            read: { reading.withLock { $0 } },
            observesNotifications: false
        )
        let hikeRecorder = makeRecorder(powerMonitor: monitor)
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))
        await settleDelegateHop()
        #expect(source.currentProfile == .precise)

        reading.withLock { $0 = PowerState(isLowPowerModeEnabled: true) }
        monitor.refresh()
        // Named rather than best-effort: `observePowerState()` is an
        // `Observations` loop, so the effect lands a few scheduler hops after
        // `refresh()` — monitor notices, sequence yields, loop resumes,
        // profile is applied. A fixed number of round trips buys an amount of
        // progress that depends on how loaded the machine is, which is the
        // flake `SettleSupport` exists to remove.
        await settleDelegateHop(until: "the conserving profile to be applied") {
            self.source.currentProfile?.desiredAccuracy
                == RecordingEnergyPolicy.conservingAccuracy
        }

        #expect(
            source.currentProfile?.desiredAccuracy
                == RecordingEnergyPolicy.conservingAccuracy
        )
    }

    /// Re-evaluated on every accepted fix, so a walk at steady conditions has
    /// to resolve to one configuration rather than flipping between profiles.
    @Test("An unchanged profile is not re-applied")
    func unchangedProfileIsNotReapplied() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()

        for step in 0..<4 {
            clock.advance(by: 10)
            source.deliver(fix(latitude: 47.63 + Double(step) * 0.0004))
            await settleDelegateHop()
        }

        #expect(hikeRecorder.stats.pointCount > 1, "the fixes have to have landed")
        #expect(
            source.appliedProfiles.count == 1,
            "only the initial configuration should have reached CoreLocation"
        )
    }

    /// ``resolvedEnergyProfile()`` only lets `isStationary` through while
    /// fixes are being taken, so a session that is not capturing them resolves
    /// to `.precise` rather than to the wide stationary filter.
    @Test("A stopped session is never described as stationary")
    func inactiveSessionIsNotStationary() {
        let hikeRecorder = makeRecorder()

        #expect(hikeRecorder.isCapturingFixes == false)
        #expect(hikeRecorder.resolvedEnergyProfile() == .precise)
    }
}
