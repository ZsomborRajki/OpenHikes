//
//  OpenTrailsModel.swift
//  OpenTrails
//
//  App-wide dependencies and coordination shared by the scene and root view.
//

import AsyncAlgorithms
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

    let defaults: UserDefaults

    convenience init() {
        let launchDefaults = AppLaunchEnvironment.makeDefaults()

        if AppLaunchEnvironment.isUITesting {
            do {
                try self.init(
                    uiTestingDefaults: launchDefaults
                )
                return
            } catch {
                fatalError(
                    "OpenTrails could not create its UI-testing container: "
                        + error.localizedDescription
                )
            }
        }

        // Built explicitly so background relaunch services and the view
        // hierarchy share one SwiftData store.
        let load = Self.loadDefaultContainer()

        self.init(
            container: load.container,
            backgroundTracker: BackgroundTrailTracker(
                container: load.container,
                defaults: launchDefaults
            ),
            autoSaveController: AutoSaveController(),
            hikeRecorder: HikeRecorder(
                container: load.container,
                elevationSource: SystemRecordingElevationSource(),
                motionSource: SystemRecordingMotionSource(),
                trailGraphProvider: OverpassTrailGraphProvider(),
                distanceEvidenceSource: SystemPedometerDistanceSource(),
                defaults: launchDefaults,
                sharedStateStore: AppGroupRecordingSharedStateStore()
            ),
            locationManager: LocationManager(),
            weatherManager: WeatherManager(),
            defaults: launchDefaults,
            startupIssue: load.startupIssue
        )
    }

    private convenience init(
        uiTestingDefaults: UserDefaults
    ) throws {
        let testingContainer = try ModelContainer(
            for: Hike.self,
            configurations: ModelConfiguration(
                isStoredInMemoryOnly: true
            )
        )
        self.init(
            container: testingContainer,
            backgroundTracker: BackgroundTrailTracker(
                container: testingContainer,
                defaults: uiTestingDefaults
            ),
            autoSaveController: AutoSaveController(),
            hikeRecorder: HikeRecorder(
                container: testingContainer,
                trailGraphProvider: AppLaunchEnvironment
                    .trailGraphFixtureName
                    .flatMap { name in
                        BundledTrailGraphProvider(fixtureName: name)
                    },
                defaults: uiTestingDefaults,
                journalDirectory:
                    AppLaunchEnvironment.recordingJournalDirectory(),
                automaticallyRecovers: false
            ),
            locationManager: LocationManager(),
            weatherManager: WeatherManager(),
            defaults: uiTestingDefaults
        )
    }

    private static func loadDefaultContainer() -> ContainerLoadResult {
        do {
            return try loadContainer(
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
            let msg = "Neither the persistent nor temporary SwiftData store"
                + " could be opened: \(error.localizedDescription)"
            logger.fault("\(msg, privacy: .public)")
            fatalError("OpenTrails could not create a SwiftData container.")
        }
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
            let msg = "The persistent SwiftData store could not be opened;"
                + " using temporary storage for this launch: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
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
        if !AppLaunchEnvironment.isUITesting {
            backgroundTracker.refreshBasemaps()
        }
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
        let finishedHike = hike.flatMap { selectedHike in
            selectedHike.belongsToActiveRecording(
                currentHikeID: currentRecordingHikeID
            ) ? nil : selectedHike
        }
        autoSaveController.hikeSelectionChanged(to: finishedHike)
        if !AppLaunchEnvironment.isUITesting {
            backgroundTracker.hikeSelectionChanged(to: finishedHike)
        }
        defaults.set(
            finishedHike?.id.uuidString,
            forKey: SettingsKey.lastSelectedHikeID
        )
    }

    func restoreLastSelectedHike(in modelContext: ModelContext) -> Hike? {
        guard !AppLaunchEnvironment.isRunningTests,
              let stored = defaults.string(
                forKey: SettingsKey.lastSelectedHikeID
              ),
              let id = UUID(uuidString: stored) else { return nil }

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

        TileCache.scheduleMaintenance {
            let keys = claims.reduce(into: Set<String>()) { result, ownership in
                result.formUnion(ownership.tileKeys())
            }
            TileCache.shared.trimCache(claimedBy: keys)
        }
    }

    /// Keeps ``WeatherManager`` current for wherever the walker is, waking on
    /// two things and nothing else: a new position, and the moment
    /// ``WeatherPollState`` would next allow a request for the position it
    /// already holds.
    ///
    /// The second wake-up is one sleep to an exact deadline, re-armed after
    /// each pass — not a tick. Standing still with a fresh reading, this loop
    /// wakes twice in a quarter of an hour; the 1 Hz timer it replaces woke
    /// nine hundred times over the same stretch to conclude it had nothing to
    /// do, and `WeatherPollState` threw all but one of those away. Keeping the
    /// deadline is what stops the other extreme: purely fix-driven polling
    /// would leave an expired reading, or a failure's backoff, waiting on the
    /// walker to move again.
    func pollWeather(policy: WeatherPollingPolicy = .standard) async {
        var state = WeatherPollState()
        let (dueDates, dueDatesContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var dueTask: Task<Void, Never>?
        defer {
            dueTask?.cancel()
            dueDatesContinuation.finish()
        }

        for await _ in merge(locationManager.fixes.map { _ in () }, dueDates) {
            guard let coordinate = locationManager.coordinate else { continue }
            let key = Self.weatherKey(for: coordinate)
            if state.shouldRequest(key: key, at: .now, policy: policy) {
                if await weatherManager.update(for: coordinate) {
                    state.recordSuccess(key: key, at: .now)
                } else {
                    state.recordFailure(key: key, at: .now, policy: policy)
                }
            }
            dueTask?.cancel()
            guard let due = state.nextEligibleDate(key: key, policy: policy) else { continue }
            dueTask = Task {
                try? await Task.sleep(until: .now + .seconds(max(0, due.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                dueDatesContinuation.yield(())
            }
        }
    }

    private static func weatherKey(
        for coordinate: CLLocationCoordinate2D
    ) -> String {
        "\(Int(coordinate.latitude * 100)),\(Int(coordinate.longitude * 100))"
    }
}
