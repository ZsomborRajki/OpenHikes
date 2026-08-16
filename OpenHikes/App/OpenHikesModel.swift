//
//  OpenHikesModel.swift
//  OpenHikes
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
final class OpenHikesModel {
    struct ContainerLoadResult {
        let container: ModelContainer
        let startupIssue: StorageStartupIssue?
    }

    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Persistence"
    )

    let container: ModelContainer
    let backgroundTracker: BackgroundTrailTracker
    let autoSaveController: AutoSaveController
    let hikeRecorder: HikeRecorder
    let locationManager: LocationManager
    let weatherManager: WeatherManager
    /// The OSM walking graph, shared with ``hikeRecorder`` rather than built
    /// per consumer: it owns a durable cache, an in-flight request table and
    /// the retry deadline Overpass hands back when it rate-limits us. A second
    /// instance would keep its own copy of all three and double the request
    /// rate against a volunteer-run API.
    let trailGraphProvider: (any TrailGraphProviding)?
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
                    "OpenHikes could not create its UI-testing container: "
                        + error.localizedDescription
                )
            }
        }

        // Built explicitly so background relaunch services and the view
        // hierarchy share one SwiftData store.
        let load = Self.loadDefaultContainer()
        let graphProvider = OverpassTrailGraphProvider()

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
                trailGraphProvider: graphProvider,
                distanceEvidenceSource: SystemPedometerDistanceSource(),
                defaults: launchDefaults,
                sharedStateStore: AppGroupRecordingSharedStateStore()
            ),
            locationManager: LocationManager(),
            weatherManager: WeatherManager(),
            trailGraphProvider: graphProvider,
            defaults: launchDefaults,
            startupIssue: load.startupIssue
        )
    }

    private convenience init(
        uiTestingDefaults: UserDefaults
    ) throws {
        let testingContainer = try RenderSignpost.interval("ModelContainerInit") {
            () throws(Swift.Error) in
            try ModelContainer(
                for: Hike.self,
                configurations: ModelConfiguration(
                    isStoredInMemoryOnly: true
                )
            )
        }
        let graphProvider = AppLaunchEnvironment
            .trailGraphFixtureName
            .flatMap { name in
                BundledTrailGraphProvider(fixtureName: name)
            }
        self.init(
            container: testingContainer,
            backgroundTracker: BackgroundTrailTracker(
                container: testingContainer,
                defaults: uiTestingDefaults
            ),
            autoSaveController: AutoSaveController(),
            hikeRecorder: HikeRecorder(
                container: testingContainer,
                trailGraphProvider: graphProvider,
                defaults: uiTestingDefaults,
                journalDirectory:
                    AppLaunchEnvironment.recordingJournalDirectory(),
                automaticallyRecovers: false
            ),
            locationManager: LocationManager(),
            weatherManager: WeatherManager(),
            trailGraphProvider: graphProvider,
            defaults: uiTestingDefaults
        )
    }

    private static func loadDefaultContainer() -> ContainerLoadResult {
        do {
            return try loadContainer(
                persistent: {
                    try RenderSignpost.interval("ModelContainerInit") {
                        () throws(Swift.Error) in
                        try ModelContainer(for: Hike.self)
                    }
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
            fatalError("OpenHikes could not create a SwiftData container.")
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
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        defaults: UserDefaults = .standard,
        startupIssue: StorageStartupIssue? = nil
    ) {
        self.container = container
        self.backgroundTracker = backgroundTracker
        self.autoSaveController = autoSaveController
        self.hikeRecorder = hikeRecorder
        self.locationManager = locationManager
        self.weatherManager = weatherManager
        self.trailGraphProvider = trailGraphProvider
        self.defaults = defaults
        self.startupIssue = startupIssue
    }

    func sceneDidBecomeActive() {
        autoSaveController.sceneDidBecomeActive()
        if !AppLaunchEnvironment.isRunningTests {
            backgroundTracker.refreshBasemaps()
        }
        hikeRecorder.sceneDidBecomeActive()
    }

    func sceneWillResignActive() {
        hikeRecorder.sceneWillResignActive()
        autoSaveController.sceneWillResignActive {
            try container.mainContext.save()
        }
        #if DEBUG
        // The last moment a measured run can count on: UI automation
        // backgrounds the app and only then terminates it, so this is what
        // gets the tail of the scenario onto disk.
        PerformanceLog.shared?.flush()
        #endif
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
        if !AppLaunchEnvironment.isRunningTests {
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
        guard track.points.count > 1 else { throw .tooShort }

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

    /// Evicts cached tiles no hike claims any more, down to the cache limit.
    ///
    /// A fetch that fails sweeps nothing rather than sweeping with an empty
    /// claim set: ``TileCache/trimCache(claimedBy:limit:)`` tells a hike's
    /// downloaded offline map apart from browsing residue by nothing but that
    /// set, so an empty one makes every durable tile evictable.
    func trimTileCache(in modelContext: ModelContext) {
        // Auto-save can have tiles on disk that no manifest claims yet.
        autoSaveController.flushPendingKeys()
        guard let claims = try? Self.tileClaims(fetchingHikes: {
            try modelContext.fetch(FetchDescriptor<Hike>())
        }) else { return }

        TileCache.scheduleMaintenance {
            // A cancelled enumeration trims nothing rather than a partial
            // claim set: an under-reported claim is indistinguishable from an
            // unclaimed tile, and would evict a hike's saved map.
            var keys = Set<String>()
            for ownership in claims {
                guard let claimed = try? ownership.tileKeys() else { return }
                keys.formUnion(claimed)
            }
            TileCache.shared.trimCache(claimedBy: keys)
        }
    }

    /// Deletes photo files that no hike claims any more.
    ///
    /// The companion to ``trimTileCache(in:)``, and run in the same breath:
    /// photo file deletion is fire-and-forget, so a hike deleted moments
    /// before the app was killed leaves its pictures on disk with nothing
    /// pointing at them and no screen that could ever show them again.
    ///
    /// A fetch that fails sweeps nothing rather than sweeping with an empty
    /// claim set — the same rule the tile trim follows, and for the same
    /// reason: an under-reported claim would delete every photo in the app.
    func reclaimOrphanedPhotos(
        in modelContext: ModelContext,
        store: HikePhotoStore = .shared
    ) {
        guard let claimed = try? Self.photoClaims(fetchingHikes: {
            try modelContext.fetch(FetchDescriptor<Hike>())
        }) else { return }
        Task(priority: .utility) { await Self.reclaim(claimed, in: store) }
    }

    @concurrent
    private static func reclaim(_ claimed: Set<String>, in store: HikePhotoStore) async {
        store.reclaimOrphans(claimedBy: claimed)
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

// MARK: - Launch sweep claims

/// What authorizes the two launch sweeps to delete anything.
///
/// Both hand a claim set to code whose whole job is removing what is not in
/// it, and neither `TileCache.trimCache(claimedBy:)` nor
/// `HikePhotoStore.reclaimOrphans(claimedBy:)` can tell an honestly empty set
/// from one a failed fetch produced. So these `throw` rather than returning
/// an empty set: the distinction is in the type, and the call sites above can
/// only spend a claim set they actually have.
///
/// `static` and closure-driven for the same reason
/// ``OpenHikesModel/loadContainer(persistent:fallback:)`` is — the branch that
/// matters is the failing one, and nothing else makes SwiftData throw on
/// demand.
extension OpenHikesModel {
    /// Every hike that is holding tiles, as the ownership records a trim is
    /// measured against.
    static func tileClaims(
        fetchingHikes fetch: () throws -> [Hike]
    ) rethrows -> [TileOwnership] {
        try fetch().filter(\.hasStoredTiles).map(TileOwnership.init)
    }

    /// Every file name any hike's photos occupy — the picture and its
    /// thumbnail both, since a thumbnail left unclaimed is deleted and
    /// silently re-rendered.
    static func photoClaims(
        fetchingHikes fetch: () throws -> [Hike]
    ) rethrows -> Set<String> {
        var claimed = Set<String>()
        for photo in try fetch().flatMap(\.photos) {
            claimed.insert(photo.fileName)
            claimed.insert(photo.thumbnailFileName)
        }
        return claimed
    }
}
