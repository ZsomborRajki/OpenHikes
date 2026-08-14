//
//  RecordingEnergyPolicyTests.swift
//  OpenHikesTests
//
//  The GPS configuration is the single largest thing this app spends a
//  walker's battery on, and it is now a function rather than a constant. These
//  pin the function.
//
//  Written as a table of conditions rather than as narrative scenarios,
//  because what matters about this policy is that no combination of inputs
//  produces a configuration nobody intended — a hike recorded at hundred-metre
//  accuracy because two mitigations composed badly is a hike whose route is
//  wrong, and the walker would not find out until they got home.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Recording energy policy")
struct RecordingEnergyPolicyTests {
    @Test("Nothing asking for less means full accuracy")
    func nominalConditionsRecordPrecisely() {
        let profile = RecordingEnergyPolicy.profile(for: .init())

        #expect(profile.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(profile.distanceFilter == RecordingEnergyPolicy.walkingDistanceFilter)
        #expect(profile.name == "precise")
        #expect(profile.reason == nil)
        #expect(profile == .precise)
    }

    @Test("Low Power Mode lowers accuracy and widens the filter")
    func lowPowerModeConserves() {
        let profile = RecordingEnergyPolicy.profile(
            for: .init(isLowPowerModeEnabled: true)
        )

        #expect(profile.desiredAccuracy == RecordingEnergyPolicy.conservingAccuracy)
        #expect(profile.distanceFilter == RecordingEnergyPolicy.conservingDistanceFilter)
        #expect(profile.reason != nil)
    }

    /// The one that would quietly ruin every summer hike if it were wrong: a
    /// phone in a sunlit pocket sits at `.fair` for hours, so treating that as
    /// a signal would make the conserving profile the normal one and amount to
    /// having lowered the default.
    @Test(
        "Thermal pressure conserves only from serious upward",
        arguments: [
            (ProcessInfo.ThermalState.nominal, false),
            (.fair, false),
            (.serious, true),
            (.critical, true),
        ]
    )
    func thermalThreshold(state: ProcessInfo.ThermalState, conserves: Bool) {
        #expect(RecordingEnergyPolicy.conserves(state) == conserves)

        let profile = RecordingEnergyPolicy.profile(for: .init(thermalState: state))
        let expected = conserves
            ? RecordingEnergyPolicy.conservingAccuracy
            : kCLLocationAccuracyBest
        #expect(profile.desiredAccuracy == expected)
    }

    /// Standing still is allowed to cost fewer wakeups but never a coarser
    /// fix: the first fix after setting off again anchors the next leg of the
    /// recorded route, and buying energy with it is a bad trade for something
    /// the hiker keeps.
    @Test("Standing still widens the filter without lowering accuracy")
    func stationaryWidensFilterOnly() {
        let profile = RecordingEnergyPolicy.profile(for: .init(isStationary: true))

        #expect(profile.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(profile.distanceFilter == RecordingEnergyPolicy.stationaryDistanceFilter)
        #expect(profile.distanceFilter > RecordingEnergyPolicy.walkingDistanceFilter)
    }

    /// Two reasons to be woken less often must not combine into a reason to be
    /// woken more often, which is what taking the later of the two filters
    /// rather than the larger would do.
    @Test("Combined conditions take the widest filter, never a narrower one")
    func conditionsCompose() {
        let both = RecordingEnergyPolicy.profile(
            for: .init(isLowPowerModeEnabled: true, isStationary: true)
        )

        #expect(both.desiredAccuracy == RecordingEnergyPolicy.conservingAccuracy)
        #expect(
            both.distanceFilter == max(
                RecordingEnergyPolicy.conservingDistanceFilter,
                RecordingEnergyPolicy.stationaryDistanceFilter
            )
        )
        #expect(both.name.contains("low-power"))
        #expect(both.name.contains("stationary"))
    }

    /// A conserving recording that stopped producing acceptable fixes would be
    /// a battery saving that lost the hike. Ten-metre accuracy has to stay
    /// inside the gate the recorder applies to every fix.
    @Test("Every profile still produces fixes the recorder will accept")
    func conservingAccuracyStaysAcceptable() {
        for conditions: RecordingEnergyPolicy.Conditions in [
            .init(),
            .init(isLowPowerModeEnabled: true),
            .init(thermalState: .critical),
            .init(isLowPowerModeEnabled: true, thermalState: .critical, isStationary: true),
        ] {
            let profile = RecordingEnergyPolicy.profile(for: conditions)
            #expect(profile.desiredAccuracy < RecordingFixPolicy.maximumHorizontalAccuracy)
            #expect(profile.distanceFilter > 0)
        }
    }
}

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
