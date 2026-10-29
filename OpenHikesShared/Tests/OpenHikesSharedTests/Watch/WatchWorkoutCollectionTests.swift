//
//  WatchWorkoutCollectionTests.swift
//  OpenHikesSharedTests
//
//  What the watch's workout session goes on collecting, out of what a live
//  data source would collect for it. Which defaults HealthKit picks for a
//  hike depends on the watch and on the hiker's settings, and no suite here
//  can ask, so each case is a set the decision has to get right whatever
//  HealthKit hands it. The identifiers are HealthKit's own constants, from the
//  macOS SDK, so the string the package names heart rate by is the one
//  HealthKit means.
//

import Foundation
import HealthKit
@testable import OpenHikesShared
import Testing

@Suite("What the watch's workout session collects")
struct WatchWorkoutCollectionTests {
    static let heartRate = HKQuantityTypeIdentifier.heartRate.rawValue
    static let activeEnergy = HKQuantityTypeIdentifier.activeEnergyBurned.rawValue
    static let basalEnergy = HKQuantityTypeIdentifier.basalEnergyBurned.rawValue
    static let distance = HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue

    /// What Apple's *Running workout sessions* says an outdoor run collects
    /// and saves.
    static let outdoorRun: Set = [activeEnergy, basalEnergy, heartRate, distance]
    /// The same session for a hiker whose watch is set to wheelchair use,
    /// one of "the person's settings" the defaults vary with.
    static let wheelchair: Set = [
        activeEnergy,
        basalEnergy,
        heartRate,
        HKQuantityTypeIdentifier.distanceWheelchair.rawValue,
        HKQuantityTypeIdentifier.pushCount.rawValue,
    ]
    /// Defaults holding a type this app has never named, as a later watchOS
    /// might add to a hike.
    static let laterWatchOS: Set = outdoorRun.union([HKQuantityTypeIdentifier.physicalEffort.rawValue])

    @Test("the one type the watch reads is HealthKit's heart rate")
    func theWatchReadsHeartRate() {
        // A misspelling here would stop the screen's only heart-rate feed,
        // and the figure would be a dash for a whole walk with nothing to
        // say why.
        #expect(WatchWorkoutCollection.heartRate == Self.heartRate)
        #expect(WatchWorkoutCollection.read == [Self.heartRate])
    }

    @Test("energy and distance stop, and heart rate goes on as HealthKit set it up")
    func onlyHeartRateGoesOn() {
        let collection = WatchWorkoutCollection(defaults: Self.outdoorRun)
        // Before #1210 the data source kept all four, and every discarded
        // workout left in Health whatever they had collected.
        #expect(collection.kept == [Self.heartRate])
        #expect(collection.stopped == [Self.activeEnergy, Self.basalEnergy, Self.distance])
    }

    @Test("nothing is turned on: defaults without heart rate all stop")
    func nothingIsTurnedOn() {
        let defaults: Set = [Self.activeEnergy, Self.distance]
        let collection = WatchWorkoutCollection(defaults: defaults)
        // A session that shows no heart rate, as it did before, rather than
        // a collection this app picked and HealthKit never offered.
        #expect(collection.kept.isEmpty)
        #expect(collection.stopped == defaults)
    }

    @Test(
        "every default is kept or stopped, and only heart rate is kept",
        arguments: [Self.outdoorRun, Self.wheelchair, Self.laterWatchOS, []]
    )
    func everyDefaultIsDecided(defaults: Set<String>) {
        let collection = WatchWorkoutCollection(defaults: defaults)
        #expect(collection.kept.union(collection.stopped) == defaults)
        #expect(collection.kept.isDisjoint(with: collection.stopped))
        #expect(collection.kept.isSubset(of: [Self.heartRate]))
    }
}
