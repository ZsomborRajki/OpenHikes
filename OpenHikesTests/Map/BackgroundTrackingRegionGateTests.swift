//
//  BackgroundTrackingRegionGateTests.swift
//  OpenHikesTests
//
//  Who is allowed to have a region registered with the system, which is a
//  different question from what the app does with the answer —
//  `BackgroundTrackingProximityTests` owns that one, and every launch in it has
//  the feature switched on.
//
//  The registration is the part that outlives the process. A condition added to
//  a `CLMonitor` persists until it is removed, so it survives a force-quit and
//  the system will relaunch this app when the phone crosses it. That is exactly
//  what Background Trail Tracking is for and exactly what its switch being off
//  is meant to mean, so the switch has to reach it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

// Nested in the widget-feed group for the reason `BackgroundTrackingProximityTests`
// gives: selecting a trail publishes the App Group snapshot, and that file is
// shared with the suites there.
extension WidgetFeedSuites {
@Suite("Background tracking region gate", .serialized)
final class BackgroundTrackingRegionGateTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    /// Held for the length of the test: the monitor references its delegate
    /// weakly, exactly as CoreLocation does.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        monitor.authorization = .always
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    private func tracker(
        regionMonitor: FakeTrailRegionMonitor
    ) -> BackgroundTrailTracker {
        let newTracker = BackgroundTrailTracker(
            container: container,
            monitor: monitor,
            regionMonitor: regionMonitor,
            defaults: defaults
        )
        retainedTracker = newTracker
        return newTracker
    }

    @discardableResult private func seedSelection() throws -> Hike {
        let hike = Fixture.hike(in: context, route: Fixture.ridgeRoute)
        try context.save()
        defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID)
        return hike
    }

    /// A region a build that registered one regardless of the toggle left
    /// behind, which is the state this gate has to be able to get out of.
    private func inheritedCondition() async -> FakeTrailRegionMonitor {
        let regionMonitor = FakeTrailRegionMonitor()
        await regionMonitor.setRegion(
            TrailRegion(route: Fixture.ridgeRoute.map(\.clCoordinate))
        )
        return regionMonitor
    }

    /// The upgrade path, and the reason the clearing happens at launch rather
    /// than only where the switch is flipped: a hiker whose phone is already
    /// carrying a condition never flips anything, so nothing else would ever
    /// take it away.
    @Test("a launch with the feature off removes a condition an earlier build left")
    func launchWithTheFeatureOffRemovesAnInheritedCondition() async throws {
        try seedSelection()
        let regionMonitor = await inheritedCondition()
        let registrationsBefore = await regionMonitor.setRegionCount

        await tracker(regionMonitor: regionMonitor).waitForTrailRegionWatch()

        #expect(await regionMonitor.registeredRegion == nil)
        #expect(await regionMonitor.setRegionCount == registrationsBefore + 1)
        #expect(defaults.bool(forKey: SettingsKey.trailRegionCleared))
    }

    /// And the reason it is remembered: with the feature off there is nothing
    /// left to remove, and asking again costs a `CLLocationManager` and an XPC
    /// connection on every launch for an answer that cannot change.
    @Test("a later launch with the feature off does not open the monitor at all")
    func aClearedLaunchAsksNothing() async throws {
        try seedSelection()
        defaults.set(true, forKey: SettingsKey.trailRegionCleared)
        let regionMonitor = FakeTrailRegionMonitor()

        await tracker(regionMonitor: regionMonitor).waitForTrailRegionWatch()

        #expect(await regionMonitor.setRegionCount == 0)
        #expect(await regionMonitor.observerCount == 0)
    }

    /// The reported shape of the bug. Opening a trail is not consent to a
    /// standing geofence; the switch in Settings is.
    @Test("selecting a trail with the feature off registers no condition")
    func selectionWithTheFeatureOffRegistersNothing() async throws {
        defaults.set(true, forKey: SettingsKey.trailRegionCleared)
        let regionMonitor = FakeTrailRegionMonitor()
        let tracker = tracker(regionMonitor: regionMonitor)
        let hike = Fixture.hike(in: context, route: Fixture.ridgeRoute)
        try context.save()

        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        #expect(await regionMonitor.setRegionCount == 0)
        #expect(await regionMonitor.registeredRegion == nil)
    }

    /// Always is the other half: `CLMonitor` cannot evaluate a condition
    /// without it, so one registered then is a geofence nothing can read and
    /// nothing will remove.
    @Test("selecting a trail without Always registers no condition")
    func selectionWithoutAlwaysRegistersNothing() async throws {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        defaults.set(true, forKey: SettingsKey.trailRegionCleared)
        monitor.authorization = .whenInUse
        let regionMonitor = FakeTrailRegionMonitor()
        let tracker = tracker(regionMonitor: regionMonitor)
        let hike = Fixture.hike(in: context, route: Fixture.ridgeRoute)
        try context.save()

        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        #expect(await regionMonitor.setRegionCount == 0)
    }

    /// The feature working, which none of the above may break.
    @Test("selecting a trail with the feature on registers its region")
    func selectionWithTheFeatureOnRegisters() async throws {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        defaults.set(true, forKey: SettingsKey.trailRegionCleared)
        let regionMonitor = FakeTrailRegionMonitor()
        let tracker = tracker(regionMonitor: regionMonitor)
        let hike = Fixture.hike(in: context, route: Fixture.ridgeRoute)
        try context.save()

        tracker.hikeSelectionChanged(to: hike)
        await tracker.waitForSelectionPublish()

        #expect(await regionMonitor.registeredRegion != nil)
        #expect(
            !defaults.bool(forKey: SettingsKey.trailRegionCleared),
            "something is registered again, so the cached answer is no longer true"
        )
    }

    /// Turning the feature off has to *remove* the condition, not merely stop
    /// arming on what it says. Leaving it is what left a standing geofence —
    /// and the background launches it buys — behind a switch the hiker had
    /// turned off.
    @Test("turning the feature off removes the registered condition")
    func turningTheFeatureOffRemovesTheCondition() async {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        let regionMonitor = await inheritedCondition()
        let tracker = tracker(regionMonitor: regionMonitor)
        await tracker.waitForTrailRegionWatch()
        #expect(await regionMonitor.registeredRegion != nil, "precondition")

        defaults.set(false, forKey: SettingsKey.backgroundTrackingEnabled)
        tracker.setEnabled(false)
        await tracker.waitForTrailRegionWatch()

        #expect(await regionMonitor.registeredRegion == nil)
        #expect(defaults.bool(forKey: SettingsKey.trailRegionCleared))
    }

    /// A launch with the feature on is untouched by any of this: it watches,
    /// and the selection that follows registers.
    @Test("a launch with the feature on watches the region")
    func launchWithTheFeatureOnWatches() async throws {
        try seedSelection()
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        let regionMonitor = FakeTrailRegionMonitor()

        await tracker(regionMonitor: regionMonitor).waitForTrailRegionWatch()

        #expect(await regionMonitor.observerCount == 1)
        #expect(await regionMonitor.setRegionCount == 0, "a launch watches; a selection registers")
    }
}
}
