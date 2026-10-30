//
//  HikeDetailStorageRefreshTests.swift
//  OpenHikesTests
//
//  Returning from a pushed screen keeps the detail's state, but restarts its
//  task. Later auto-save drains must still reach a new byte measurement.
//

import AsyncAlgorithms
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Hike detail storage refresh", .timeLimit(.minutes(1)))
struct HikeDetailStorageRefreshTests {
    private let sandbox = TileSandbox()
    private let clock = CommunitySearchClock()
    private let quietPeriod = Duration.seconds(5)

    private func screen(for hike: Hike, in context: ModelContext) throws -> HikeDetailView {
        let defaults = try #require(UserDefaults(suiteName: "HikeDetailStorageRefreshTests-\(UUID())"))
        let time = TestClock()
        return HikeDetailView(
            hike: hike,
            highlight: RouteHighlight(),
            mapController: MapController(),
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil),
            entitlement: MapEntitlementStore(defaults: defaults, currentEntitlements: { false }),
            settings: StoredSettings(defaults: defaults),
            locationManager: LocationManager(manager: DormantLocationSource()),
            backgroundTracker: BackgroundTrailTracker(
                container: context.container,
                monitor: DormantLocationSource(),
                regionMonitor: FakeTrailRegionMonitor(),
                defaults: defaults,
                clock: time.read
            ),
            selectedLine: SelectedLine(),
            lineStoreWatch: SelectedLineStoreWatch { /* nothing saved here */ },
            walkSession: TrailWalkSession(context: context, clock: time.read)
        )
    }

    @Test("a drain after reader cancellation and restart still measures the new tiles")
    func restartedReaderMeasuresLaterDrains() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let detail = try screen(for: hike, in: context)
        let firstKey = "osm/16/9/9"
        let secondKey = "osm/16/9/10"
        try sandbox.save(key: firstKey)
        hike.autoSavedTileKeys = [firstKey]
        var measurements: [Int64] = []
        var readerEnded = false

        func read() -> Task<Void, Never> {
            let events = detail.storedBytesRefreshEvents()
            return Task {
                for await generation in events.debounce(for: quietPeriod, clock: clock) {
                    guard generation == detail.storedBytesMeasurementGeneration else { continue }
                    let bytes = try? await OfflineStorageMeasurement.measure(
                        route: hike.route,
                        offlineDownloads: hike.offlineDownloads,
                        autoSavedTileKeys: hike.autoSavedTileKeys,
                        cache: sandbox.cache
                    )
                    if let bytes { measurements.append(bytes) }
                }
                readerEnded = true
            }
        }

        let first = read()
        detail.scheduleStoredBytesRefresh()
        await settleDelegateHop(until: "the first drain's debounce wait") { clock.pendingWaits == 1 }
        clock.advance(by: quietPeriod)
        await settleDelegateHop(until: "the first byte measurement") { measurements.count == 1 }
        #expect(measurements.first.map { $0 > 0 } == true)
        first.cancel()
        await first.value

        readerEnded = false
        let second = read()
        defer { second.cancel() }
        try sandbox.save(key: secondKey)
        hike.autoSavedTileKeys.append(secondKey)
        detail.scheduleStoredBytesRefresh()
        await settleDelegateHop(until: "the restarted reader to debounce a new drain or finish") {
            clock.pendingWaits == 1 || readerEnded
        }
        #expect(!readerEnded, "a restarted detail task must have a live notification stream")
        guard !readerEnded else { return }
        clock.advance(by: quietPeriod)
        await settleDelegateHop(until: "the restarted reader's new byte measurement") { measurements.count == 2 }
        #expect(measurements.count == 2)
        #expect(measurements.last == measurements.first.map { $0 * 2 })
    }
}
