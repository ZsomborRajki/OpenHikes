//
//  OpenHikesApp.swift
//  OpenHikes
//
//  Created by Zsombor Rajki on 2026. 06. 18..
//

import AppIntents
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
        // rather than the first frame is the boundary a walker experiences.
        if !AppLaunchEnvironment.isRunningTests {
            LaunchMeasurement.begin()
        }
        #if DEBUG
        // Ordinary UI automation keeps the watchdog off — its ping loop is one
        // more thread competing with the runner. A *measured* launch is the
        // exception: a stall it never reported is a stall the report cannot
        // contain.
        if !AppLaunchEnvironment.isUITesting
            || AppLaunchEnvironment.performanceLogScenario != nil {
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
        let appModel = RenderSignpost.interval("AppModelInit") {
            OpenHikesModel()
        }
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
        }
    }

    var body: some Scene {
        WindowGroup {
            OpenHikesView()
                .environment(model)
                .defaultAppStorage(model.defaults)
                .ignoresSafeArea()
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
