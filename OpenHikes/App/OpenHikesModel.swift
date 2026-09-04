//
//  OpenHikesModel.swift
//  OpenHikes
//
//  App-wide dependencies and coordination shared by the scene and root view.
//
//  What this file holds is the list: what the app depends on, and the handful
//  of decisions that have to be made *between* those dependencies rather than
//  inside any one of them. Everything that is a subject of its own sits beside
//  it, so this list stays readable as one:
//
//  - `OpenHikesModel+Composition.swift` — how a launch assembles one, and which
//    store it opens.
//  - `OpenHikesModel+SceneLifecycle.swift` — leaving the foreground and coming
//    back.
//  - `OpenHikesModel+Weather.swift` — the polling loop.
//  - `OpenHikesModel+LaunchSweeps.swift` — the two deletions that run at launch.
//

import Foundation
import Observation
import SwiftData

nonisolated struct StorageStartupIssue: Equatable, Sendable {
    let underlyingDescription: String
}

@Observable
final class OpenHikesModel {
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
    /// Reports on the CloudKit mirroring SwiftData does for the store built
    /// above, and remembers whether the user wants it at all.
    ///
    /// Deliberately does *not* carry tiles or anything else describing this
    /// device's disk: see ``HikeLocalState``, which lives in the second,
    /// unmirrored store for exactly that reason.
    let cloudSync: CloudSyncCoordinator
    /// Whether the two commercial map sources are unlocked, and the paywall's
    /// backing store. Built here rather than per-view because the answer has to
    /// outlive Settings: ``MapEntitlement`` is read on every provider
    /// resolution, including from off-main auto-save.
    let entitlement: MapEntitlementStore
    var startupIssue: StorageStartupIssue?

    let defaults: UserDefaults

    /// Distinguishes the `.inactive` step of leaving the foreground from the
    /// one on the way back, which are otherwise identical.
    ///
    /// Held here rather than as `@State` on the scene: `@State` invalidates
    /// its declaring view whether or not `body` reads it, and this one is read
    /// by nothing that draws. In the class body rather than beside the handlers
    /// in `OpenHikesModel+SceneLifecycle.swift` because a stored property
    /// cannot live in an extension, which is also why it is not `private`.
    @ObservationIgnored var lifecycleGate = SceneLifecycleGate()

    init(
        container: ModelContainer,
        backgroundTracker: BackgroundTrailTracker,
        autoSaveController: AutoSaveController,
        hikeRecorder: HikeRecorder,
        locationManager: LocationManager,
        weatherManager: WeatherManager,
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        defaults: UserDefaults = .standard,
        startupIssue: StorageStartupIssue? = nil,
        isSyncingThisLaunch: Bool = false
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
        // `storageIsDurable` is the whole of what a failed store means to
        // sync: the fallback container is in-memory, and an in-memory store
        // does not mirror whatever the switch says.
        cloudSync = CloudSyncCoordinator(
            defaults: defaults,
            isSyncingThisLaunch: isSyncingThisLaunch,
            storageIsDurable: startupIssue == nil
        )
        cloudSync.start()
        // A UI test cannot buy anything, and a suite that hosts the app must
        // not reach the App Store at all — so both take a stubbed answer and
        // only a real launch starts StoreKit.
        if AppLaunchEnvironment.isRunningTests {
            let stub = MapEntitlementStore(
                defaults: Self.entitlementDefaults(defaults),
                currentEntitlements: { AppLaunchEnvironment.grantsPaidMaps }
            )
            entitlement = stub
            Task { await stub.refresh() }
        } else {
            let store = MapEntitlementStore(defaults: defaults)
            entitlement = store
            store.start()
        }
        // Behind the test guard for the same reason every other startup writer
        // is: both unit-test bundles are hosted by the app, and a delivered
        // payload would write into Application Support underneath a suite that
        // owns its own store. Nothing arrives during a test run in practice —
        // MetricKit reports daily and only on a device — but "in practice" is
        // not a guarantee, and this costs one branch.
        if !AppLaunchEnvironment.isRunningTests {
            FieldMetrics.shared.register()
        }
    }

    /// Where a test host's stubbed entitlement remembers its answer.
    ///
    /// UI tests already run against their own defaults suite, so that is where
    /// it goes. A unit-test host does not: both unit bundles are hosted by the
    /// app, which launches against `.standard`, and a stub publishing there
    /// would leave `purchases.lastKnownMapEntitlement` in the developer's own
    /// defaults and decide which map their *next real launch* draws. A named
    /// suite, wiped as it is handed over, keeps the write path exercised and
    /// lands nowhere that outlives the run.
    private static let testHostEntitlementSuite = "com.openhikes.testhost.entitlement"

    private static func entitlementDefaults(_ launchDefaults: UserDefaults) -> UserDefaults {
        guard !AppLaunchEnvironment.isUITesting,
              let isolated = UserDefaults(suiteName: testHostEntitlementSuite)
        else { return launchDefaults }
        isolated.removePersistentDomain(forName: testHostEntitlementSuite)
        return isolated
    }

    func selectedHikeDidChange(to hike: Hike?) {
        let finishedHike = browsableHike(hike)
        autoSaveController.hikeSelectionChanged(to: finishedHike)
        if !AppLaunchEnvironment.isRunningTests {
            backgroundTracker.hikeSelectionChanged(to: finishedHike)
        }
        defaults.set(
            finishedHike?.id.uuidString,
            forKey: SettingsKey.lastSelectedHikeID
        )
    }

    /// Re-evaluates tile auto-save after the map source changed.
    ///
    /// Only auto-save: the widget's background matching and the stored
    /// selection have nothing to do with which map is drawn, and republishing
    /// them here would spend a widget reload on a settings tap.
    func tileProviderDidChange(selectedHike hike: Hike?) {
        autoSaveController.hikeSelectionChanged(to: browsableHike(hike))
    }

    /// An active recording is selected in the list, but it is not a finished
    /// route to browse, auto-save for, or match background fixes against. The
    /// recorder owns its live trace and widget state.
    private func browsableHike(_ hike: Hike?) -> Hike? {
        let currentRecordingHikeID = hikeRecorder.currentHike?.id
        return hike.flatMap { selectedHike in
            selectedHike.belongsToActiveRecording(
                currentHikeID: currentRecordingHikeID
            ) ? nil : selectedHike
        }
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
        // The MetricKit span covers the whole import rather than only the
        // parse `GPXParsed` already times: what is worth knowing in the field
        // is what opening somebody's 20,000-point GPX costs end to end,
        // including the SwiftData insert, and that is not a number a
        // three-point fixture can produce.
        let span = FieldSignpost.begin(.hikeImport)
        defer {
            FieldSignpost.end(span)
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let track = try await GPXImport.loadOffMain(from: url)
        guard track.points.count > 1 else { throw .tooShort }

        let hike = Hike(
            // Bounded here rather than absorbed downstream: this name came out
            // of a file the walker may never have opened. See ``HikeTitle``.
            title: HikeTitle.imported(trackName: track.name, fileURL: url),
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
}
