//
//  OpenHikesModel+Composition.swift
//  OpenHikes
//
//  How a launch builds the model: which SwiftData store it opens, and which of
//  the environment's real sensors, policies and save paths the dependencies
//  are handed.
//
//  Apart from ``OpenHikesModel`` itself because it answers a different
//  question. The class is the list of what the app depends on and what it
//  coordinates between them; this is the one place the *production* choices
//  behind each of those dependencies are named — a real pedometer, a real
//  barometer, a mirrored container, the user's own defaults — and every one of
//  them has a test double behind the same parameter of the designated
//  initializer. Keeping the two apart is what stops that list from reading as
//  though the app could only ever be assembled one way.
//

import Foundation
import os
import SwiftData
import Synchronization

// MARK: - Assembling a launch

extension OpenHikesModel {
    struct ContainerLoadResult {
        let container: ModelContainer
        let startupIssue: StorageStartupIssue?
    }

    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Persistence"
    )

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
        //
        // The switch has to be read here rather than by the coordinator: a
        // `ModelConfiguration` decides whether it mirrors when it is created,
        // and it is created before there is a coordinator to ask.
        //
        // Behind the test guard for the reason every other startup writer is,
        // and more sharply: both unit-test bundles are hosted by the app, so a
        // mirrored container here would have the host reach for the developer's
        // real iCloud account and their real hikes underneath suites that own
        // their own store.
        let syncsToCloud = !AppLaunchEnvironment.isRunningTests
            && CloudSyncCoordinator.isEnabled(in: launchDefaults)
        let load = Self.loadDefaultContainer(syncsToCloud: syncsToCloud)
        let graphProvider = OverpassTrailGraphProvider()

        self.init(
            container: load.container,
            backgroundTracker: BackgroundTrailTracker(
                container: load.container,
                defaults: launchDefaults
            ),
            autoSaveController: Self.makeAutoSaveController(defaults: launchDefaults),
            hikeRecorder: Self.makeRecorder(
                container: load.container,
                trailGraphProvider: graphProvider,
                defaults: launchDefaults
            ),
            locationManager: LocationManager(),
            weatherManager: WeatherManager(),
            trailGraphProvider: graphProvider,
            defaults: launchDefaults,
            startupIssue: load.startupIssue,
            isSyncingThisLaunch: syncsToCloud
        )
    }

    private convenience init(
        uiTestingDefaults: UserDefaults
    ) throws {
        let testingContainer = try RenderSignpost.interval("ModelContainerInit") {
            () throws(Swift.Error) in
            try ModelContainer.openHikes(isStoredInMemoryOnly: true)
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
            autoSaveController: Self.makeAutoSaveController(defaults: uiTestingDefaults),
            hikeRecorder: HikeRecorder(
                container: testingContainer,
                saveModelContext: Self.uiTestingSave(),
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
}

// MARK: - Opening the store

extension OpenHikesModel {
    private static func loadDefaultContainer(syncsToCloud: Bool) -> ContainerLoadResult {
        do {
            return try loadContainer(
                persistent: {
                    try RenderSignpost.interval("ModelContainerInit") {
                        () throws(Swift.Error) in
                        try ModelContainer.openHikes(syncsToCloud: syncsToCloud)
                    }
                },
                fallback: {
                    try ModelContainer.openHikes(isStoredInMemoryOnly: true)
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
}

// MARK: - Recording composition

private extension OpenHikesModel {
    /// The app's real recorder, with its system-backed sensors and the live
    /// tile network policy wired in.
    ///
    /// Assembled here rather than inline in `init` because every one of these
    /// arguments is a *choice about the environment* — a real pedometer, a
    /// real barometer, the user's actual cellular and Low Power Mode
    /// settings — and each has a test double behind the same parameter. This
    /// is the one place the production ones are named.
    static func makeRecorder(
        container: ModelContainer,
        trailGraphProvider: any TrailGraphProviding,
        defaults: UserDefaults
    ) -> HikeRecorder {
        HikeRecorder(
            container: container,
            elevationSource: SystemRecordingElevationSource(),
            motionSource: SystemRecordingMotionSource(),
            trailGraphProvider: trailGraphProvider,
            distanceEvidenceSource: SystemPedometerDistanceSource(),
            // Downloading a walking graph for ground the recording never saw
            // is a tile-sized fetch on the same connection, so it answers to
            // the same cellular, Low Power Mode and thermal rules the tiles
            // do — see ``TileNetworkPolicy``.
            trailGraphNetworkDecision: { purpose in
                TileCache.shared.networkDecision(for: purpose)
            },
            defaults: defaults,
            sharedStateStore: AppGroupRecordingSharedStateStore()
        )
    }

    /// The auto-save controller wired to the real selected map source.
    ///
    /// Same argument as ``makeRecorder(container:trailGraphProvider:defaults:)``:
    /// "which map the user picked" is a choice about the environment, and the
    /// controller takes it as a closure so a suite can decide it outright
    /// instead of inheriting whatever the host app has stored. Read on each
    /// call rather than captured once, so a change made in Settings takes
    /// effect on the next selection without rebuilding anything.
    static func makeAutoSaveController(defaults: UserDefaults) -> AutoSaveController {
        AutoSaveController {
            !TileProvider.selected(in: defaults).usesSystemBaseMap
        }
    }
}

// MARK: - UI-test seams

/// The refusals a UI-testing launch can ask for. Held apart from the model's
/// own body because none of it runs outside a `--ui-testing` launch: the only
/// caller is the UI-testing initializer above, and it is reached only when
/// ``AppLaunchEnvironment/isUITesting`` is true.
extension OpenHikesModel {
    /// The recorder's save, refused once when the launch asked for it.
    ///
    /// The retry path is the only branch of the recording screen no sequence
    /// of taps can reach: it needs the store to say no. The recorder already
    /// takes its save as a closure — the seam is what the unit suites drive —
    /// so a scenario borrows it rather than the app growing a second one, and
    /// everything the screen does afterwards is the shipping state machine.
    ///
    /// Refused once, and only for the save that ends a recording. The recorder
    /// writes several times before then — the draft hike it inserts when
    /// recording starts, the orphans it sweeps — and failing one of those
    /// would put the screen in a state that has nothing to retry
    /// (``HikeRecorder/canRetrySave`` is false until a prepared save is
    /// pending). The finalising write is the one that has already flipped
    /// `isRecording` off, which is what identifies it here.
    ///
    /// Once, not always: a retry that could never succeed would prove the
    /// button exists and nothing about what it does.
    static func uiTestingSave() -> (ModelContext) throws -> Void {
        guard AppLaunchEnvironment.failsFirstSave else {
            return { context in try context.save() }
        }
        let hasFailed = Mutex(false)
        return { context in
            let finalizesRecording = (
                context.insertedModelsArray + context.changedModelsArray
            ).contains { model in
                (model as? Hike).map { !$0.isRecording } ?? false
            }
            let shouldFail = hasFailed.withLock { failed in
                guard finalizesRecording, !failed else { return false }
                failed = true
                return true
            }
            guard !shouldFail else {
                throw CocoaError(.fileWriteUnknown)
            }
            try context.save()
        }
    }
}
