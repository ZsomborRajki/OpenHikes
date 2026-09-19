//
//  OpenHikesApp.swift
//  OpenHikes
//
//  Created by Zsombor Rajki on 2026. 06. 18..
//

import AppIntents
import OpenHikesShared
import SwiftData
import SwiftUI

@main
struct OpenHikesApp: App {
    @Environment(\.scenePhase)
    private var scenePhase

    @State private var model: OpenHikesModel

    init() {
        // Before anything else: the API requires this to start no later than
        // the first scene connecting, and `init()` runs at
        // `didFinishLaunching` time. Paired with `LaunchMeasurement.finish()`
        // where the map is built — see `FieldSignpost.swift` for why the map
        // rather than the first frame is the boundary a hiker experiences.
        if !AppLaunchEnvironment.isRunningTests {
            LaunchMeasurement.begin()
        }
        #if DEBUG
        // UI automation keeps the watchdog off: its ping loop is one more
        // thread competing with the runner.
        if !AppLaunchEnvironment.isUITesting {
            MainThreadWatchdog.start()
        }
        #endif
        if !AppLaunchEnvironment.isRunningTests {
            TileCache.scheduleMaintenance {
                TileCache.shared.removeExpiredTiles()
                // After the TTL sweep, so a store only counts tiles it is
                // actually still keeping. This normally frees nothing — the
                // reservation on the write path is what holds the line — but it
                // is what brings an install saved before the ceiling existed
                // back under a provider's terms.
                TileCache.shared.enforceDurableByteLimits()
            }
        }

        // Constructed here, not lazily inside a view, because a background
        // relaunch (triggered by a significant-location-change event) runs
        // `init()` unconditionally but may never reach a view's `.task`/
        // `.onAppear` — `BackgroundTrailTracker`'s significant-change monitor
        // has to already be re-armed and delegated by the time this returns,
        // or the relaunch's one pending location event has nothing to deliver
        // to.
        let appModel = OpenHikesModel()
        _model = State(initialValue: appModel)

        // The system may launch this process purely to run an App Intent, in
        // which case no view is ever built and nothing else registers the
        // coordinator — so it happens here, beside the model it is built from,
        // rather than in a `.task`.
        //
        // Behind the test guard for the reason the startup writers above are:
        // both unit-test bundles are hosted by the app, and a coordinator
        // registered here would hold the host's own recorder and store while
        // the suites run against theirs. Intent tests supply their own through
        // `HikeIntentContext.$override` and never read the registration.
        //
        // Built here and handed over, rather than inside the call: `add` takes
        // its dependency as an `@autoclosure @Sendable` the framework may run
        // anywhere, and a main-actor type cannot be constructed in one.
        if !AppLaunchEnvironment.isRunningTests {
            let coordinator = HikeIntentCoordinator(
                recorder: appModel.hikeRecorder,
                container: appModel.container
            )
            AppDependencyManager.shared.add(dependency: coordinator)
            let recordingControl: any HikeRecordingControlHandling = coordinator
            AppDependencyManager.shared.add(dependency: recordingControl)
            // Spotlight, which is the half of ``HikeEntity`` a hiker gets
            // without having to say anything. Here beside the registration
            // because it wants the same coordinator, and off the main actor
            // because it is a whole-library fetch nothing on screen waits for.
            HikeSpotlightIndex.donate(from: coordinator)
            // The App Group's copy of the library, and a trail snapshot for
            // every hike a placed widget is pinned to. Beside the Spotlight
            // sweep because it is the same sweep argument — see
            // ``SharedHikeCataloguePublisher``.
            SharedHikeCataloguePublisher.publish(
                from: coordinator,
                container: appModel.container,
                watch: appModel.watchLink
            )
            // The watch's own link, started here rather than in a `.task` for
            // the reason the intent registration above is: `WCSession` can
            // wake this process to deliver a walk a hiker recorded hours ago,
            // and a session activated by a view is a session that does not
            // exist on that launch.
            appModel.watchLink?.activate()
            // The Live Activity's own buttons, registered the same way and for
            // the same reason: the intent type is compiled into the widget
            // extension and performed here.
            let activityControl: any HikeActivityControlHandling = coordinator
            AppDependencyManager.shared.add(dependency: activityControl)
            // The one intent that reaches the view tree rather than the store.
            // Registered from the model's instance rather than a fresh one,
            // because a request left on a second object is a request nothing
            // is watching — see ``HikeOpenRequests``.
            AppDependencyManager.shared.add(dependency: appModel.hikeOpenRequests)
        }
    }

    var body: some Scene {
        WindowGroup {
            // No `.ignoresSafeArea()` here: the map asks for that itself, one
            // level down, and asking for it out here as well threw the safe
            // area away for everything else in the window — which is how the
            // landscape side panel came to sit under the Dynamic Island. See
            // ``MapSidePanel``.
            OpenHikesView()
                .environment(model)
                .defaultAppStorage(model.defaults)
        }
        .modelContainer(model.container)
        // The widget's basemaps need the network to render, so a trail
        // selected offline (or during a background relaunch) can end up
        // without them. Re-checking on every foreground is how that heals;
        // it's a bounds comparison and no work when they're already right.
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
    }
}
