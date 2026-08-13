//
//  OpenTrailsModel.swift
//  OpenTrails
//
//  App-wide dependencies and coordination shared by the scene and root view.
//

import CoreLocation
import Foundation
import Observation
import os
import SwiftData

nonisolated struct StorageStartupIssue: Equatable, Sendable {
    let underlyingDescription: String
}

@Observable
final class OpenTrailsModel {
    struct ContainerLoadResult {
        let container: ModelContainer
        let startupIssue: StorageStartupIssue?
    }

    private static let logger = Logger(
        subsystem: "OpenTrails",
        category: "Persistence"
    )

    let container: ModelContainer
    let backgroundTracker: BackgroundTrailTracker
    let autoSaveController: AutoSaveController
    let hikeRecorder: HikeRecorder
    let locationManager: LocationManager
    let weatherManager: WeatherManager
    var startupIssue: StorageStartupIssue?

    private let defaults: UserDefaults

    convenience init() {
        // Built explicitly so background relaunch services and the view
        // hierarchy share one SwiftData store.
        let load: ContainerLoadResult
        do {
            load = try Self.loadContainer(
                persistent: {
                    try ModelContainer(for: Hike.self)
                },
                fallback: {
                    try ModelContainer(
                        for: Hike.self,
                        configurations: ModelConfiguration(
                            isStoredInMemoryOnly: true
                        )
                    )
                }
            )
        } catch {
            Self.logger.fault(
                "Neither the persistent nor temporary SwiftData store could be opened: \(error.localizedDescription, privacy: .public)"
            )
            fatalError("OpenTrails could not create a SwiftData container.")
        }

        self.init(
            container: load.container,
            backgroundTracker: BackgroundTrailTracker(
                container: load.container
            ),
            autoSaveController: AutoSaveController(),
            hikeRecorder: HikeRecorder(
                container: load.container,
                elevationSource: SystemRecordingElevationSource(),
                motionSource: SystemRecordingMotionSource(),
                trailGraphProvider: OverpassTrailGraphProvider(),
                distanceEvidenceSource: SystemPedometerDistanceSource(),
                sharedStateStore: AppGroupRecordingSharedStateStore()
            ),
            locationManager: LocationManager(),
            weatherManager: WeatherManager(),
            startupIssue: load.startupIssue
        )
    }

    static func loadContainer(
        persistent: () throws -> ModelContainer,
        fallback: () throws -> ModelContainer
    ) throws -> ContainerLoadResult {
        do {
            return ContainerLoadResult(
                container: try persistent(),
                startupIssue: nil
            )
        } catch {
            logger.error(
                "The persistent SwiftData store could not be opened; using temporary storage for this launch: \(error.localizedDescription, privacy: .public)"
            )
            return ContainerLoadResult(
                container: try fallback(),
                startupIssue: StorageStartupIssue(
                    underlyingDescription: error.localizedDescription
                )
            )
        }
    }

    init(
        container: ModelContainer,
        backgroundTracker: BackgroundTrailTracker,
        autoSaveController: AutoSaveController,
        hikeRecorder: HikeRecorder,
        locationManager: LocationManager,
        weatherManager: WeatherManager,
        defaults: UserDefaults = .standard,
        startupIssue: StorageStartupIssue? = nil
    ) {
        self.container = container
        self.backgroundTracker = backgroundTracker
        self.autoSaveController = autoSaveController
        self.hikeRecorder = hikeRecorder
        self.locationManager = locationManager
        self.weatherManager = weatherManager
        self.defaults = defaults
        self.startupIssue = startupIssue
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
        // An active recording is selected in the list, but it is not a
        // finished route to browse, auto-save for, or match background fixes
        // against. The recorder owns its live trace and widget state.
        let currentRecordingHikeID = hikeRecorder.currentHike?.id
        let finishedHike = hike.flatMap {
            $0.belongsToActiveRecording(
                currentHikeID: currentRecordingHikeID
            ) ? nil : $0
        }
        autoSaveController.hikeSelectionChanged(to: finishedHike)
        backgroundTracker.hikeSelectionChanged(to: finishedHike)
        defaults.set(
            finishedHike?.id.uuidString,
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
