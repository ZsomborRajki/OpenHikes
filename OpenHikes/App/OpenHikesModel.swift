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
    /// The walk under way along a followed trail, if any. Owned here rather
    /// than by the detail view because it outlives the screen that starts it
    /// — see ``TrailWalkSession``.
    let walkSession: TrailWalkSession
    let locationManager: LocationManager
    let weatherManager: WeatherManager
    /// What the weather badge is about. Written by the three places that can
    /// say — the recorder, hike selection and search — and read by nothing
    /// else; see ``WeatherSubject``.
    let weatherFocus: WeatherFocus
    /// Movement, coarsely, for the things that care about a region rather than
    /// a position. Only the weather poll uses it today. Armed and disarmed
    /// with the foreground — see ``sceneDidBecomeActive()``.
    let significantLocations: SignificantLocationFeed
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
    /// The published hikes the sheet is showing, and the thresholds that
    /// decide when to ask for more — see ``CommunityBrowser``.
    ///
    /// Owned here rather than by the sheet because two screens feed it and
    /// neither owns the other: the map reports a settled region to it, and the
    /// sheet draws its results. A `@State` in either would be rebuilt by the
    /// other's navigation.
    let community: CommunityBrowser
    /// How a hike is shared and how a shared one is opened, or `nil` for a
    /// launch that must not reach CloudKit — see
    /// ``makeCommunityTransport()``. Held so the share sheet and the preview
    /// screen use the same one the browser does.
    let communityTransport: (any CommunityTransporting)?
    /// The one reminder controller the app has, or `nil` when it must not have
    /// one — see ``makeMovementReminderController(defaults:)``. Shared with
    /// ``hikeRecorder`` and ``walkSession``, which is what makes the
    /// precedence between a recording and a followed trail expressible.
    let movementReminders: MovementReminderController?
    /// What the buttons on a reminder do. Held because
    /// `UNUserNotificationCenter.delegate` is a weak reference and this is the
    /// object it points at; built only when there are reminders to act on.
    @ObservationIgnored private var reminderActions: MovementReminderActions?
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
        significantLocations: SignificantLocationFeed,
        trailGraphProvider: (any TrailGraphProviding)? = nil,
        movementReminders: MovementReminderController? = nil,
        walkSession: TrailWalkSession? = nil,
        communityTransport: (any CommunityTransporting)? = nil,
        defaults: UserDefaults = .standard,
        startupIssue: StorageStartupIssue? = nil,
        isSyncingThisLaunch: Bool = false
    ) {
        self.container = container
        self.backgroundTracker = backgroundTracker
        self.autoSaveController = autoSaveController
        self.hikeRecorder = hikeRecorder
        self.movementReminders = movementReminders
        // The recorder stays the single authority on which hike is a draft;
        // the session only asks.
        self.walkSession = walkSession ?? TrailWalkSession(
            context: container.mainContext,
            tracker: backgroundTracker,
            reminders: movementReminders,
            activeRecordingHikeID: { [weak hikeRecorder] in hikeRecorder?.currentHike?.id }
        )
        self.communityTransport = communityTransport
        community = CommunityBrowser(transport: communityTransport)
        self.locationManager = locationManager
        self.weatherManager = weatherManager
        self.significantLocations = significantLocations
        // Seeded from whatever the manager restored, so a launch that comes
        // back with last night's reading is also pointed at the place that
        // reading was for — otherwise the badge would show a subject the poll
        // loop has never heard of and would not refresh until the user did
        // something. A restored subject is replaced by the first real focus.
        weatherFocus = WeatherFocus(subject: weatherManager.state.subject)
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
        // Behind the same guard, and for the same reason: adopting a walk
        // writes the sidecar and pins the tracker, underneath suites that own
        // their own. Here rather than in the root view's launch task because
        // a background relaunch never shows a view — see
        // ``TrailWalkSession/restoreAtLaunch(now:)``.
        if !AppLaunchEnvironment.isRunningTests, startupIssue == nil {
            self.walkSession.restoreAtLaunch()
        }
        // Last, because both halves need dependencies built above: the
        // recorder answers the precedence question the walk's reminder asks,
        // and the buttons act on the recorder and the session. Only a launch
        // that has a controller registers a delegate — a suite has neither.
        if let movementReminders {
            movementReminders.hasActiveRecording = { [weak hikeRecorder] in
                hikeRecorder?.isActive ?? false
            }
            // A second `HikeIntentCoordinator` beside the one `OpenHikesApp`
            // registers with `AppDependencyManager`, and deliberately: the
            // coordinator owns no state of its own — it holds this recorder
            // and this container and reads the phase back — so the two cannot
            // disagree, and reaching for the registered one would mean asking
            // `AppDependencyManager` for something a test launch never
            // registers, which traps rather than returning nil.
            reminderActions = MovementReminderActions(
                recording: HikeIntentCoordinator(
                    recorder: hikeRecorder,
                    container: container
                ),
                walkSession: self.walkSession
            ).registerAsNotificationDelegate()
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
}
