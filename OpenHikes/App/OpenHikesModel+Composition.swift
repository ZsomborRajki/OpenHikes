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

        let parts = Self.makeDependencies(
            container: load.container,
            defaults: launchDefaults
        )

        self.init(
            container: load.container,
            backgroundTracker: parts.backgroundTracker,
            autoSaveController: parts.autoSave,
            hikeRecorder: parts.recorder,
            locationManager: parts.locationManager,
            weatherManager: parts.weatherManager,
            significantLocations: parts.significantLocations,
            trailGraphProvider: parts.graphProvider,
            movementReminders: parts.reminders,
            communityTransport: parts.communityTransport,
            defaults: launchDefaults,
            startupIssue: load.startupIssue,
            isSyncingThisLaunch: syncsToCloud
        )
    }

    private convenience init(
        uiTestingDefaults: UserDefaults
    ) throws {
        let testingContainer = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
        // The two paths build different things: this one takes dormant
        // location sources and a bundled trail graph, so what carries across
        // is the shape rather than the numbers — which dependency dominates,
        // and whether anything here is doing real work at launch that a name
        // would not suggest.
        let parts = Self.makeUITestingDependencies(
            container: testingContainer,
            defaults: uiTestingDefaults
        )
        self.init(
            container: testingContainer,
            backgroundTracker: parts.backgroundTracker,
            autoSaveController: parts.autoSave,
            hikeRecorder: parts.recorder,
            locationManager: parts.locationManager,
            weatherManager: parts.weatherManager,
            significantLocations: parts.significantLocations,
            trailGraphProvider: parts.graphProvider,
            // Asked here as well as on the shipping path, which it was not.
            // A UI-test launch still gets `nil` out of this unless it named a
            // scenario — that guard is inside the factory — but until this
            // line existed there was no argument a scenario could pass that
            // would have made any difference, because this initializer never
            // called it. The feature was unreachable from automation by
            // composition rather than by policy.
            communityTransport: parts.communityTransport,
            defaults: uiTestingDefaults
        )
    }

    /// The browser, with a geocoder only for the launches that have a
    /// transport and are not automation.
    ///
    /// Tied to the transport rather than built unconditionally, and for the
    /// same reason: the launches that must not reach CloudKit must not reach
    /// MapKit's geocoder either, and a browser that will never ask anything
    /// has no area to name. See ``CommunityAreaNaming``.
    ///
    /// UI testing is now the case where those two came apart. A scenario that
    /// names a seeded database *has* a transport and still must not reach the
    /// network, so the geocoder stays behind. What that costs is the area name
    /// — the header reads "Community Hikes" rather than "Near Bad Reichenhall"
    /// — and what it buys is a heading that says the same thing on a machine
    /// with no signal as on one with, which is the only kind a test can assert
    /// against anyway.
    static func makeCommunityBrowser(
        transport: (any CommunityTransporting)?,
        blocks: CommunityBlockList
    ) -> CommunityBrowser {
        let namesAreas = transport != nil && !AppLaunchEnvironment.isUITesting
        return CommunityBrowser(
            transport: transport,
            blockList: blocks,
            areaNames: namesAreas ? GeocodedAreaNames() : nil
        )
    }

    /// The trail maker, pointed at the unmirrored store a half-drawn trail
    /// belongs in — see ``TrailDraftRecord`` for why that is the one it
    /// belongs in and what the choice costs (nothing: no `CD_` type, no
    /// Console index, no mirrored-schema entry).
    ///
    /// The container's main context, like ``TrailWalkSession``'s: both are
    /// main-actor SwiftData work driven by a hiker's own gestures rather than
    /// by a feed, so neither wants a background context of its own.
    ///
    /// Unguarded by ``AppLaunchEnvironment/isRunningTests``, unlike
    /// ``makeWatchLink(container:)``. A hosted suite gets whatever container
    /// the host built, which for a test launch is in-memory, so there is
    /// nothing here that could reach the developer's own disk — and UI
    /// automation needs the maker to work for the same reason it needs the
    /// recorder to.
    ///
    /// The hiking router is the recorder's own trail-graph provider wrapped in
    /// ``OverpassTrailLegRouter``, so a drawn leg reads the z12 tiles a
    /// recording has already downloaded and a recording reads the ones a
    /// drawing downloaded. `nil` when there is no provider — a launch under
    /// UI automation with no `--ui-test-trail-graph=` fixture — and the maker
    /// then draws straight lines and does not offer a switch it could not
    /// honour in Hiking mode. Other modes use Apple Maps directions.
    static func makeTrailMaker(
        container: ModelContainer,
        graph trailGraphProvider: (any TrailGraphProviding)?,
        defaults: UserDefaults
    ) -> TrailDraftController {
        TrailDraftController(
            store: TrailDraftStore(context: container.mainContext),
            router: trailGraphProvider.map { provider in
                OverpassTrailLegRouter(provider: provider)
            },
            placeSource: Self.makeTrailPointSource(),
            elevationSource: Self.makeTrailElevationSource(),
            naming: Self.makeTrailStopNaming(),
            travelRouters: Self.makeDirectionsRouters(),
            // The model's own defaults, so a UI-testing launch keeps its
            // recents in the scratch domain rather than the developer's.
            recents: TrailStopRecents(defaults: defaults),
            placeFilter: TrailPlaceFilter(defaults: defaults)
        )
    }

    /// Tests exercise the selector without asking Apple's live service. Unit
    /// suites inject geometry at the router seam; UI launches get a no-route answer.
    static func makeDirectionsRouters() -> [TrailTravelMode: any TrailLegRouting] {
        var routers: [TrailTravelMode: any TrailLegRouting] = [:]
        for mode in TrailTravelMode.allCases where mode != .hiking {
            if AppLaunchEnvironment.isRunningTests {
                routers[mode] = DirectionsTrailLegRouter(mode: mode, calculate: { _, _ in [] })
            } else {
                routers[mode] = DirectionsTrailLegRouter(mode: mode)
            }
        }
        return routers
    }

    /// What a point put down by a tap on the map is called, or `nil` for a
    /// launch that must not ask.
    ///
    /// The same guard the two sources above make, and here it is about
    /// determinism rather than money: MapKit's reverse geocoding costs nothing
    /// but it answers with whatever is on the ground under the runner's
    /// simulated coordinate, so a suite that fell into it would assert on a row
    /// whose text is a fact about Apple's map data and the network the machine
    /// was on. Under tests every stop reads its role — *Start*, *Stop 2*,
    /// *Destination* — which is what ``TrailMakerUITests`` finds rows by.
    ///
    /// `nil` rather than a stub, so nothing is queued at all — see
    /// ``TrailStopNamer/canAsk``, the same shape
    /// ``TrailDraftElevation/isAvailable`` takes.
    static func makeTrailStopNaming() -> (any TrailStopNaming)? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return MapKitTrailStopNaming()
    }

    /// Where the maker's climb and descent come from, or `nil` for a launch
    /// that must not ask.
    ///
    /// The same guard ``makeTrailPointSource()`` makes, for the commercial
    /// half of the same reason: every call is billed against the key the paid
    /// map styles are behind, and a suite that fell into it would be spending
    /// real money to assert on a stub's worth of numbers.
    ///
    /// ``StadiaElevationSource``'s own entitlement check is the *other* guard
    /// and not a substitute for this one. That one asks whether the hiker has
    /// paid; this one asks whether anybody is watching — and a developer
    /// running the suite may well be a subscriber, which is exactly the launch
    /// where the first guard would let every assertion reach the network.
    ///
    /// `nil` rather than ``DormantElevationSource`` so nothing is even
    /// scheduled: see ``TrailDraftElevation/isAvailable``, which is what keeps
    /// a suite from holding a debounce it will never spend.
    static func makeTrailElevationSource() -> (any CuratedElevationSourcing)? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return StadiaElevationSource()
    }

    /// Where the maker's *Search this area* asks, or `nil` for a launch that
    /// must not ask anything.
    ///
    /// Guarded on ``AppLaunchEnvironment/isRunningTests`` exactly as
    /// ``makeCommunityTransport()`` is, and for the harder half of the same
    /// reason: this one reaches a **volunteer-run** public API that hands out
    /// a handful of slots per address, so a suite that fell into it would be
    /// spending a real hiker's quota to assert on a stub's worth of rows.
    ///
    /// The `nil` is not a stub and is not a failure either: it withdraws the
    /// pill, the same shape ``TrailDraftController/canSnapToPaths`` takes for
    /// a launch with no trail graph. A control that cannot answer is worse
    /// than no control.
    static func makeTrailPointSource() -> (any TrailPointSourcing)? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return TrailPointSource()
    }
}

// MARK: - The watch

extension OpenHikesModel {
    /// The link to a paired Apple Watch, or `nil` for a launch that must not
    /// open one.
    ///
    /// `isRunningTests` rather than `isHostingTests`, and stricter than the
    /// Live Activity's rule for the reason the Health writer's is: a
    /// `WCSession` is a *singleton with one delegate slot*, so a hosted suite
    /// that opened one would take every delivery away from the real install
    /// running beside it on the same device — and, worse, a walk arriving
    /// mid-suite would be written into whatever store the host happened to
    /// build. There is nothing here a UI test can drive either: it would need
    /// a second device on the other end of the link.
    static func makeWatchLink(container: ModelContainer) -> WatchSessionCoordinator? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return WatchSessionCoordinator(container: container)
    }
}

// MARK: - Opening the store

extension OpenHikesModel {
    private static func loadDefaultContainer(syncsToCloud: Bool) -> ContainerLoadResult {
        do {
            return try loadContainer(
                persistent: {
                    try ModelContainer.openHikes(syncsToCloud: syncsToCloud)
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
        defaults: UserDefaults,
        liveActivityController: HikeLiveActivityController?,
        movementReminders: MovementReminderController? = nil,
        workoutWriter: (any HikeWorkoutWriting)? = nil
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
            sharedStateStore: AppGroupRecordingSharedStateStore(),
            liveActivityController: liveActivityController,
            movementReminders: movementReminders,
            workoutWriter: workoutWriter
        )
    }

    /// The one movement-reminder controller the app has, or `nil` when it must
    /// not have one.
    ///
    /// `nil` under the app-hosted unit bundles for the reason the Live
    /// Activity controller is: the host app launches and runs its startup work
    /// before any test does, and a suite has no business asking the developer
    /// for notification permission or leaving a banner on their phone.
    ///
    /// `nil` under UI testing too, which is where this differs from the Live
    /// Activity controller — and the reason is the prompt rather than the
    /// banner. Notification authorization is asked for at the first pause, and
    /// a *system* alert in front of a UI test is not a thing the run can tap
    /// its way past: it would fail whichever test happened to pause first,
    /// which is a pause the walk suites take deliberately. `isRunningTests`
    /// rather than `isHostingTests` is what says both of those at once.
    ///
    /// The hiker's own switch is *not* read here. It is read on every
    /// decision instead, so turning reminders off mid-hike stops the next one
    /// rather than the one after the next launch — see
    /// ``MovementReminderController/isEnabled``.
    static func makeMovementReminderController(
        defaults: UserDefaults
    ) -> MovementReminderController? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return MovementReminderController(
            notifier: SystemMovementReminderNotifier(),
            defaults: defaults
        )
    }

    /// The one Live Activity controller the app has, or `nil` when it must not
    /// have one.
    ///
    /// One instance shared by the recorder and the trail tracker rather than
    /// one each, because the precedence rule between them — a recording
    /// outranks a followed trail — is only expressible by something that can
    /// see both. Two controllers would be two activities, and the system shows
    /// one.
    ///
    /// `nil` under the app-hosted unit bundles for the same reason the
    /// mirrored container is: the host app launches and runs its startup work
    /// before any test does, and a suite has no business putting a Live
    /// Activity on the developer's Lock Screen. UI tests keep theirs — they
    /// drive a real app out of process, and an activity is part of what they
    /// are testing.
    static func makeLiveActivityController(
        defaults: UserDefaults
    ) -> HikeLiveActivityController? {
        guard !AppLaunchEnvironment.isHostingTests else { return nil }
        return HikeLiveActivityController(
            presenter: SystemHikeActivityPresenter(),
            defaults: defaults
        )
    }

    /// The Health writer, or `nil` for a launch that must not reach HealthKit.
    ///
    /// `isRunningTests` rather than `isHostingTests`, and stricter than the
    /// Live Activity's rule for the same reason the community transport is:
    /// an activity on a Lock Screen is part of what a UI test tests, and a
    /// workout in the developer's own Health store is not — it is a real
    /// record in a real store with no sandbox behind it, exactly like a
    /// submission to the public database.
    ///
    /// `nil` is not a stub. The export simply does not happen for that launch,
    /// and everything worth asserting sits above ``HikeWorkoutWriting``, which
    /// is the whole reason that protocol exists — HealthKit is unavailable in
    /// a hosted unit test the way ActivityKit and `StoreKitTest` are.
    static func makeWorkoutWriter() -> (any HikeWorkoutWriting)? {
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        guard HealthKitWorkoutWriter.isAvailable else { return nil }
        return HealthKitWorkoutWriter()
    }

    /// The community list's backend: the public database, the curated routes,
    /// or neither.
    ///
    /// The two sources are behind **one** guard rather than two, and that is
    /// deliberate. Overpass is the safer of the pair — it is a read against a
    /// public API, where CloudKit is a write into a database every user of this
    /// app can see — but the repository's rule is that a suite reaches no
    /// network at all, and a volunteer-run service is the last one to make an
    /// exception for. A launch that is running tests gets `nil`, exactly as it
    /// did before this feature existed, and the picker stays absent.
    ///
    /// `isRunningTests` rather than `isHostingTests`, which is the stricter of
    /// the two and is the right one here: UI automation keeps its Live
    /// Activity because an activity is part of what it tests, but nothing a UI
    /// test does should put a record in a real shared database that every
    /// other user of this app can then see. There is no sandbox for the public
    /// database the way `StoreKitTest` is meant to be one for purchases — a
    /// submission made from a test is a submission.
    ///
    /// A `nil` transport is not a stub: ``CommunityBrowser`` and the share
    /// button are simply absent for that launch, the same shape
    /// ``makeLiveActivityController(defaults:)`` is absent rather than stubbed
    /// for a hosted suite.
    ///
    /// Which left the feature with no coverage at all — the picker, the list,
    /// the preview and the share flow are all downstream of this returning
    /// something, so a green UI suite said nothing about any of them. The
    /// answer is not to loosen the guard but to add a third thing it can
    /// return: ``SeededCommunityTransport``, a debug-only stand-in a scenario
    /// selects by name. Nothing reaches it by default, and no shipping build
    /// contains it.
    ///
    /// It remains the one way past the guard, and it now covers both halves:
    /// a scenario that wants curated rows gets them from a stand-in rather
    /// than from Overpass. See ``SeededCuratedTrailSource``.
    static func makeCommunityTransport() -> (any CommunityTransporting)? {
        #if DEBUG
        // Asked for by name, and the only way past the guard below. A launch
        // that does not name a scenario is unaffected by this branch, which is
        // what keeps the rule intact rather than merely mostly intact: the
        // exception is one a scenario has to spell out, not one it can fall
        // into. See ``SeededCommunityTransport`` for what it serves and why a
        // stub was worth building rather than leaving the feature uncovered.
        if let scenario = SeededCommunityTransport.Scenario(
            argument: AppLaunchEnvironment.communityScenarioName
        ) {
            let seeded = SeededCommunityTransport(scenario: scenario)
            guard scenario.servesCuratedTrails else { return seeded }
            return MergedCommunityTransport(
                published: seeded,
                curated: SeededCuratedTrailSource(),
                // Heights that reached no network either, so the chart a
                // curated hike now draws is reachable from automation.
                elevation: SeededElevationSource()
            )
        }
        #endif
        guard !AppLaunchEnvironment.isRunningTests else { return nil }
        return MergedCommunityTransport(
            published: CloudKitCommunityTransport(),
            curated: CuratedTrailSource(),
            // The one launch that may spend a billable call: a real one, with
            // a key. Every other path here keeps the dormant default — see
            // ``MergedCommunityTransport/elevation``.
            elevation: StadiaElevationSource()
        )
    }

    /// The location stack for a launch that must not have one, or `nil` when
    /// this launch should build the real `CLLocationManager`.
    ///
    /// A fresh instance per call: the foreground feed and the background
    /// tracker deliberately hold separate managers — see the file comment on
    /// ``BackgroundTrailTracker`` — and sharing one stand-in would quietly make
    /// that untrue for exactly the launches this is here to protect.
    ///
    /// Read through ``AppLaunchEnvironment/usesLiveLocation`` rather than
    /// through `isHostingTests`, because the question is the same one
    /// ``OpenHikesView`` asks before calling `start()`: two answers to "does
    /// this launch use location?" is how one of them ends up wrong.
    static func dormantLocationSource() -> DormantLocationSource? {
        AppLaunchEnvironment.usesLiveLocation ? nil : DormantLocationSource()
    }

    /// The one owner of this app's significant-change registration.
    ///
    /// Composed here, and only here, because the thing it fixes is only
    /// visible from here: ``SignificantLocationFeed`` and
    /// ``BackgroundTrailTracker`` each took a manager of their own and neither
    /// can see the other, but the registration those managers were starting
    /// and stopping is one thing the app holds. A launch is where the two are
    /// put together, so it is where the one registration belongs.
    ///
    /// Its own dormant stand-in for the same reason each consumer has one: the
    /// manager it issues the start and stop calls on is never a consumer's,
    /// and a hosted test run must not have a real one anywhere.
    static func makeSignificantLocationRegistration() -> SignificantLocationRegistration {
        SignificantLocationRegistration(monitor: Self.dormantLocationSource())
    }

    /// The auto-save controller wired to the real selected map source. ///
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

// MARK: - What a launch is made of

private extension OpenHikesModel {
    /// Every dependency the shipping composition root constructs, each behind
    /// a signpost interval of its own.
    ///
    /// A `struct` and a factory rather than ten locals in `init()`, because
    /// the linter holds an initializer to sixty lines and ten intervals do not
    /// fit beside the assembly they feed. It is otherwise the same code in the
    /// same order — a hoist, not a reordering, which matters because
    /// `liveActivities` and `reminders` are each shared by two consumers and
    /// `graphProvider` by three.
    struct LaunchDependencies {
        let graphProvider: OverpassTrailGraphProvider
        let reminders: MovementReminderController?
        let backgroundTracker: BackgroundTrailTracker
        let autoSave: AutoSaveController
        let recorder: HikeRecorder
        let locationManager: LocationManager
        let weatherManager: WeatherManager
        let significantLocations: SignificantLocationFeed
        let communityTransport: (any CommunityTransporting)?
    }

    static func makeDependencies(
        container: ModelContainer,
        defaults: UserDefaults
    ) -> LaunchDependencies {
        // Built one at a time and in this order, and the order is load-bearing
        // below rather than cosmetic: `liveActivities` and `reminders` are
        // handed to the recorder, and `graphProvider` to the matcher.
        //
        // Last measured on a Simulator, this whole block was about 100-130 ms
        // of the main thread at launch, of which opening the SwiftData
        // container was 50-58 ms and `WeatherManager` 18-27 ms. Nothing here
        // should be doing work a launch cannot defer — and the weather half of
        // that figure no longer happens here at all: the stored reading is
        // restored after the first frame instead, from `OpenHikesView`. See
        // ``WeatherManager/restoreLastReading()``.
        let graphProvider = OverpassTrailGraphProvider()
        let liveActivities = Self.makeLiveActivityController(defaults: defaults)
        let reminders = Self.makeMovementReminderController(defaults: defaults)
        let significantLocationRegistration = Self.makeSignificantLocationRegistration()
        let backgroundTracker = BackgroundTrailTracker(
            container: container,
            monitor: significantLocationRegistration.client(
                for: .trailMatching,
                monitor: Self.dormantLocationSource()
            ),
            defaults: defaults,
            liveActivityController: liveActivities
        )
        let autoSave = Self.makeAutoSaveController(defaults: defaults)
        let recorder = Self.makeRecorder(
            container: container,
            trailGraphProvider: graphProvider,
            defaults: defaults,
            liveActivityController: liveActivities,
            movementReminders: reminders,
            workoutWriter: Self.makeWorkoutWriter()
        )
        let locationManager = LocationManager(manager: Self.dormantLocationSource())
        // The geocoder is passed here and deliberately *not* on the
        // UI-testing path below: naming a forecast's place reaches MapKit's
        // network, and a launch that must not do that heads the detail sheet
        // with the subject's own name, exactly as it did before
        // ``WeatherPlaceNaming`` existed.
        let weatherManager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            placeNames: GeocodedWeatherPlaceNames(),
            // The same notifier the movement reminders use, and the same
            // refusal under test: a suite must not post banners. It is a
            // second instance rather than the controller's, because the two
            // share only the transport — the policy behind an alert is
            // ``WeatherAlertWatch`` and has nothing to do with a walk's state.
            notifier: AppLaunchEnvironment.isRunningTests
                ? nil
                : SystemMovementReminderNotifier(),
            // The same refusal, for the same reason one file down: the app
            // test bundle runs inside this process against the *real* App
            // Group, so a composed manager would publish into the file the
            // widget suites assert on — and ask WidgetKit for a redraw out of
            // a run's reload budget. See ``WeatherWidgetPublisher/inert``.
            widgetPublisher: AppLaunchEnvironment.isRunningTests ? .inert : .system
        )
        let significantLocations = SignificantLocationFeed(
            monitor: significantLocationRegistration.client(
                for: .movementFeed,
                monitor: Self.dormantLocationSource()
            )
        )
        let communityTransport = Self.makeCommunityTransport()

        return LaunchDependencies(
            graphProvider: graphProvider,
            reminders: reminders,
            backgroundTracker: backgroundTracker,
            autoSave: autoSave,
            recorder: recorder,
            locationManager: locationManager,
            weatherManager: weatherManager,
            significantLocations: significantLocations,
            communityTransport: communityTransport
        )
    }

    /// The UI-testing path's dependencies, behind the same interval names.
    ///
    /// A second factory rather than a parameter on the first, because the two
    /// paths genuinely differ: the recorder here is constructed directly with
    /// a test save seam, no automatic recovery and a journal directory the
    /// launch argument names, and the trail graph is a bundled fixture or
    /// nothing at all. A shared function taking six flags would be a worse
    /// description of a launch than two honest ones.
    static func makeUITestingDependencies(
        container: ModelContainer,
        defaults: UserDefaults
    ) -> UITestingDependencies {
        let graphProvider = AppLaunchEnvironment
            .trailGraphFixtureName
            .flatMap { name in
                BundledTrailGraphProvider(fixtureName: name)
            }
        let liveActivities = Self.makeLiveActivityController(defaults: defaults)
        let significantLocationRegistration = Self.makeSignificantLocationRegistration()
        let backgroundTracker = BackgroundTrailTracker(
            container: container,
            monitor: significantLocationRegistration.client(
                for: .trailMatching,
                monitor: Self.dormantLocationSource()
            ),
            defaults: defaults,
            liveActivityController: liveActivities
        )
        let autoSave = Self.makeAutoSaveController(defaults: defaults)
        let recorder = HikeRecorder(
            container: container,
            saveModelContext: Self.uiTestingSave(),
            trailGraphProvider: graphProvider,
            defaults: defaults,
            liveActivityController: liveActivities,
            journalDirectory: AppLaunchEnvironment.recordingJournalDirectory(),
            automaticallyRecovers: false
        )
        let locationManager = LocationManager(manager: Self.dormantLocationSource())
        // Inert for the reason the geocoder is absent above: a UI-test launch
        // must leave nothing of itself outside the app. Publishing would write
        // this run's fixture reading into the real App Group — where the
        // widget suites and the hiker's own home screen read it — and spend
        // WidgetKit reloads on it. `applyUITestSnapshot` moves the badge, so
        // without this every snapshot in every suite would do both.
        let weatherManager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            widgetPublisher: .inert
        )
        let significantLocations = SignificantLocationFeed(
            monitor: significantLocationRegistration.client(
                for: .movementFeed,
                monitor: Self.dormantLocationSource()
            )
        )
        let communityTransport = Self.makeCommunityTransport()

        return UITestingDependencies(
            graphProvider: graphProvider,
            backgroundTracker: backgroundTracker,
            autoSave: autoSave,
            recorder: recorder,
            locationManager: locationManager,
            weatherManager: weatherManager,
            significantLocations: significantLocations,
            communityTransport: communityTransport
        )
    }

    struct UITestingDependencies {
        let graphProvider: BundledTrailGraphProvider?
        let backgroundTracker: BackgroundTrailTracker
        let autoSave: AutoSaveController
        let recorder: HikeRecorder
        let locationManager: LocationManager
        let weatherManager: WeatherManager
        let significantLocations: SignificantLocationFeed
        let communityTransport: (any CommunityTransporting)?
    }
}
