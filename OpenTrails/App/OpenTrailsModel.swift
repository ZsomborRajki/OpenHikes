//
//  OpenTrailsModel.swift
//  OpenTrails
//
//  App-wide dependencies and coordination shared by the scene and root view.
//

import CoreLocation
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class OpenTrailsModel {
    let container: ModelContainer
    let backgroundTracker: BackgroundTrailTracker
    let autoSaveController: AutoSaveController
    let hikeRecorder: HikeRecorder
    let locationManager: LocationManager
    let weatherManager: WeatherManager

    private let defaults: UserDefaults

    convenience init() {
        // Built explicitly so background relaunch services and the view
        // hierarchy share one SwiftData store.
        let container = try! ModelContainer(for: Hike.self)
        let stadiaKey = Secrets.apiKey(for: .stadiaOutdoors)

        self.init(
            container: container,
            backgroundTracker: BackgroundTrailTracker(container: container),
            autoSaveController: AutoSaveController(),
            hikeRecorder: HikeRecorder(
                container: container,
                elevationSource: SystemRecordingElevationSource(),
                motionSource: SystemRecordingMotionSource(),
                trailGraphProvider: OverpassTrailGraphProvider(),
                distanceEvidenceSource: SystemPedometerDistanceSource(),
                onlineMatcher: stadiaKey.map {
                    StadiaRecordingMatcher(apiKey: $0)
                },
                onlineMatchingAvailable: { stadiaKey != nil },
                sharedStateStore: AppGroupRecordingSharedStateStore()
            ),
            locationManager: LocationManager(),
            weatherManager: WeatherManager()
        )
    }

    init(
        container: ModelContainer,
        backgroundTracker: BackgroundTrailTracker,
        autoSaveController: AutoSaveController,
        hikeRecorder: HikeRecorder,
        locationManager: LocationManager,
        weatherManager: WeatherManager,
        defaults: UserDefaults = .standard
    ) {
        self.container = container
        self.backgroundTracker = backgroundTracker
        self.autoSaveController = autoSaveController
        self.hikeRecorder = hikeRecorder
        self.locationManager = locationManager
        self.weatherManager = weatherManager
        self.defaults = defaults
    }

    func sceneDidBecomeActive() {
        autoSaveController.sceneDidBecomeActive()
        backgroundTracker.refreshBasemaps()
        hikeRecorder.sceneDidBecomeActive()
    }

    func sceneWillResignActive() {
        hikeRecorder.sceneWillResignActive()
        autoSaveController.sceneWillResignActive {
            try container.mainContext.save()
        }
    }

    func selectedHikeDidChange(to hike: Hike?) {
        autoSaveController.hikeSelectionChanged(to: hike)
        backgroundTracker.hikeSelectionChanged(to: hike)
        defaults.set(
            hike?.id.uuidString,
            forKey: SettingsKey.lastSelectedHikeID
        )
    }

    func restoreLastSelectedHike(in modelContext: ModelContext) -> Hike? {
        guard !AppLaunchEnvironment.isHostingTests,
              let stored = defaults.string(
                forKey: SettingsKey.lastSelectedHikeID
              ),
              let id = UUID(uuidString: stored) else {
            return nil
        }

        let descriptor = FetchDescriptor<Hike>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func importHike(
        from url: URL,
        into modelContext: ModelContext
    ) async throws(GPXImport.ImportFailure) -> Hike {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let track = try await GPXImport.loadOffMain(from: url)
        guard track.points.count > 1 else {
            throw .tooShort
        }

        let hike = Hike(
            title: track.name
                ?? url.deletingPathExtension().lastPathComponent,
            distanceMeters: track.distanceMeters,
            date: track.startTime ?? .now,
            tintHex: Hike.randomTintHex(),
            route: track.route,
            trackDescription: track.trackDescription,
            author: track.author,
            keywords: track.keywords
        )
        modelContext.insert(hike)
        return hike
    }

    func trimTileCache(in modelContext: ModelContext) {
        // Auto-save can have tiles on disk that no manifest claims yet.
        autoSaveController.flushPendingKeys()
        let claims = (try? modelContext.fetch(FetchDescriptor<Hike>()))?
            .filter(\.hasStoredTiles)
            .map(TileOwnership.init) ?? []

        Task.detached {
            let keys = claims.reduce(into: Set<String>()) {
                $0.formUnion($1.tileKeys())
            }
            TileCache.shared.trimCache(claimedBy: keys)
        }
    }

    func pollWeather() async {
        var state = WeatherPollState()
        while !Task.isCancelled {
            if let coordinate = locationManager.coordinate {
                let key = Self.weatherKey(for: coordinate)
                let requestedAt = Date()
                if state.shouldRequest(key: key, at: requestedAt) {
                    if await weatherManager.update(for: coordinate) {
                        state.recordSuccess(key: key, at: .now)
                    } else {
                        state.recordFailure(key: key, at: .now)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func weatherKey(
        for coordinate: CLLocationCoordinate2D
    ) -> String {
        "\(Int(coordinate.latitude * 100)),\(Int(coordinate.longitude * 100))"
    }
}
