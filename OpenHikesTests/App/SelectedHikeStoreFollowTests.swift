//
//  SelectedHikeStoreFollowTests.swift
//  OpenHikesTests
//
//  `OpenHikesModel` follows the selected hike in the store, so a line another
//  device saved for it reaches the readers the model owns, and lets the hike
//  go when nothing is selected (#1228). The watch's own behaviour is
//  `SelectedLineStoreWatchTests`', and the four readers' is
//  `SelectedLineImportTests`'; this is the wiring between the selection and
//  the watch, through a real model.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Selected hike followed in the store")
struct SelectedHikeStoreFollowTests {
    /// A real ``OpenHikesModel`` with every dependency that would otherwise
    /// reach a singleton handed in, the way `StorageStartupAlertTests` builds
    /// one, and its colours set to steepness, which needs no trail graph.
    @MainActor
    private final class ModelProbe {
        let container: ModelContainer
        let model: OpenHikesModel
        // periphery:ignore - assigned and never read on purpose; TileSandbox
        // deletes its directory on deinit, and the model above still uses it.
        private let sandbox: TileSandbox

        init() throws {
            container = try Fixture.modelContainer()
            let tiles = TileSandbox()
            sandbox = tiles
            let modelDefaults = try Self.isolatedDefaults()
            modelDefaults.set(RouteColoring.elevation.rawValue, forKey: SettingsKey.routeColoring)
            model = OpenHikesModel(
                container: container,
                backgroundTracker: BackgroundTrailTracker(
                    container: container,
                    monitor: StubLocationMonitor(),
                    defaults: try Self.isolatedDefaults()
                ),
                autoSaveController: AutoSaveController(store: tiles.store, drainInterval: nil),
                hikeRecorder: HikeRecorder(container: container),
                locationManager: LocationManager(),
                weatherManager: WeatherManager(widgetPublisher: .inert),
                significantLocations: SignificantLocationFeed(monitor: DormantLocationSource()),
                defaults: modelDefaults
            )
        }

        private static func isolatedDefaults() throws -> UserDefaults {
            let name = "com.openhikes.tests.store-follow-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            return defaults
        }
    }

    /// The ridge moved half a degree north, with its heights.
    private static let movedRoute = Fixture.ridgeRoute.map { point in
        var moved = point
        moved.latitude += 0.5
        return moved
    }

    private static func isOnMovedRoute(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        (coordinate?.latitude ?? 0) > (Fixture.ridgeRoute.last?.latitude ?? 0) + 0.4
    }

    @Test("a hike selected through the model is followed in the store, and let go with the selection")
    func theModelFollowsTheSelection() async throws {
        let probe = try ModelProbe()
        let model = probe.model
        let hike = Fixture.hike(in: probe.container.mainContext)
        try await RemoteChangeLog.save(probe.container.mainContext, settling: hike)
        let moved = Self.movedRoute

        model.selectedHikeDidChange(to: hike)
        await model.routeShading.measurement?.value
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: probe.container) { stored in
            stored.replaceRoute(with: moved)
        }
        await settleDelegateHop(until: "the model's colours follow the stored line") {
            model.routeShading.stretches.contains { Self.isOnMovedRoute($0.coordinates.first) }
        }
        #expect(hike.route == moved, "the main context's copy holds it too")

        model.selectedHikeDidChange(to: nil)
        let delivered = model.selectedLineStoreWatch.deliveredChanges
        let loop = Fixture.loopRoute
        // The store posts its change on the saving thread before the save
        // returns, so any hop it started is queued by now.
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: probe.container) { stored in
            stored.replaceRoute(with: loop)
        }
        await settleDelegateHop()

        #expect(model.selectedLineStoreWatch.deliveredChanges == delivered, "let go with the selection")
        #expect(hike.route == moved, "and its copy no longer refreshed")
    }
}
