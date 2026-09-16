//
//  PowerStateMonitorTests.swift
//  OpenHikesTests
//
//  "Power state monitor", split out of RecordingEnergyPolicyTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Power state monitor")
struct PowerStateMonitorTests {
    /// The monitor is what turns a system notification into a change the
    /// recorder can act on, so "did it actually notice" is the whole of its
    /// job.
    @Test("A changed reading is published and reported as a change")
    @MainActor
    func refreshPublishesChanges() {
        // A `Mutex` rather than a captured `var`: the reader is `@Sendable`,
        // so a local the test goes on to mutate is exactly what Swift 6
        // refuses, and correctly — the monitor may read it from anywhere.
        let reading = Mutex(PowerState())
        let monitor = PowerStateMonitor(
            read: { reading.withLock { $0 } },
            observesNotifications: false
        )

        #expect(monitor.state.isLowPowerModeEnabled == false)
        #expect(monitor.refresh() == false)

        reading.withLock { $0 = PowerState(isLowPowerModeEnabled: true) }
        #expect(monitor.refresh() == true)
        #expect(monitor.state.isLowPowerModeEnabled)
        // Republished for the nonisolated readers — `TileCache` decides
        // whether to open a connection from a background queue and cannot ask
        // the main actor.
        #expect(PowerState.current.isLowPowerModeEnabled)

        // Reset, so a suite running after this one does not inherit a process
        // that believes it is in Low Power Mode.
        reading.withLock { $0 = PowerState() }
        monitor.refresh()
    }

    @Test("isConserving follows both signals")
    func conservingFollowsBothSignals() {
        #expect(PowerState().isConserving == false)
        #expect(PowerState(isLowPowerModeEnabled: true).isConserving)
        #expect(PowerState(thermalState: .fair).isConserving == false)
        #expect(PowerState(thermalState: .serious).isConserving)
    }
}
