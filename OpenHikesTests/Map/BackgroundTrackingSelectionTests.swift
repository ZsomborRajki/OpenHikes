//
//  BackgroundTrackingSelectionTests.swift
//  OpenHikesTests
//
//  "Background tracking selection arming", split out of
//  BackgroundTrackingTests.swift so that a file declares one @Suite. That
//  file's header still holds the context the two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

extension WidgetFeedSuites {
/// Monitoring follows the *selection*, not just the settings toggle.
///
/// Serialized with the other feed suites: selecting a hike publishes a
/// snapshot to the App Group file they share, even though nothing here
/// asserts on it.
@Suite("Background tracking selection arming", .serialized)
final class BackgroundTrackingSelectionTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let monitor = StubLocationMonitor()
    // periphery:ignore - assigned and never read on purpose; it is the strong
    // reference that keeps the tracker alive.
    private var retainedTracker: BackgroundTrailTracker?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// The state a user who has turned the feature on and answered the prompt
    /// is in: everything armed except for the selection each test supplies.
    private func makeTracker(selecting hike: Hike? = nil) -> BackgroundTrailTracker {
        defaults.set(true, forKey: SettingsKey.backgroundTrackingEnabled)
        monitor.authorization = .always
        if let hike { defaults.set(hike.id.uuidString, forKey: SettingsKey.lastSelectedHikeID) }
        let newTracker = BackgroundTrailTracker(container: container, monitor: monitor, defaults: defaults)
        retainedTracker = newTracker
        return newTracker
    }

    private func hike() -> Hike {
        let newHike = Fixture.hike(in: context)
        try? context.save()
        return newHike
    }

    /// The reported bug: closing the trail left significant-change monitoring
    /// armed for good, because the only thing that ever stopped it was the
    /// settings toggle — which the user has no reason to touch.
    @Test("deselecting the trail stops monitoring")
    func deselectingStops() {
        let tracker = makeTracker(selecting: hike())
        #expect(monitor.isMonitoring, "precondition: a launch with a selection arms")

        tracker.hikeSelectionChanged(to: nil)

        #expect(monitor.stopCount == 1)
        #expect(!monitor.isMonitoring, "no trail, nothing for a wake-up to do")
    }

    /// And the toggle stays on across it: it is a standing preference, so
    /// picking a trail again has to arm monitoring without the user going
    /// back to Settings.
    @Test("selecting a trail with tracking already on arms monitoring")
    func selectingArms() {
        let tracker = makeTracker()
        #expect(monitor.startCount == 0, "precondition: nothing selected, nothing armed")

        tracker.hikeSelectionChanged(to: hike())

        #expect(monitor.startCount == 1)
        #expect(monitor.isMonitoring)
    }

    /// The selection is one of three conditions, not a replacement for the
    /// other two.
    @Test("selecting a trail with tracking off arms nothing")
    func selectingWithTrackingOffArmsNothing() {
        let tracker = makeTracker()
        defaults.set(false, forKey: SettingsKey.backgroundTrackingEnabled)

        tracker.hikeSelectionChanged(to: hike())

        #expect(monitor.startCount == 0)
    }

    /// Swapping one trail for another is a selection the feed can serve, so
    /// it must not stand monitoring down on the way through.
    @Test("swapping one trail for another leaves monitoring armed")
    func swappingTrailsStaysArmed() {
        let tracker = makeTracker(selecting: hike())

        tracker.hikeSelectionChanged(to: hike())

        #expect(monitor.isMonitoring)
        #expect(monitor.stopCount == 0)
    }
}
}
