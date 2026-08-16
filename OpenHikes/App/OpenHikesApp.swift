//
//  OpenHikesApp.swift
//  OpenHikes
//
//  Created by Zsombor Rajki on 2026. 06. 18..
//

import SwiftData
import SwiftUI

@main
struct OpenHikesApp: App {
    @Environment(\.scenePhase)
    private var scenePhase

    @State private var model: OpenHikesModel

    init() {
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
            }
        }

        // Constructed here, not lazily inside a view, because a background
        // relaunch (triggered by a significant-location-change event) runs
        // `init()` unconditionally but may never reach a view's `.task`/
        // `.onAppear` — `BackgroundTrailTracker`'s significant-change monitor
        // has to already be re-armed and delegated by the time this returns,
        // or the relaunch's one pending location event has nothing to deliver
        // to.
        _model = State(initialValue: RenderSignpost.interval("AppModelInit") {
            OpenHikesModel()
        })
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
            // Marked before either handler runs so the event file carries the
            // boundary itself. A hike is mostly spent with the screen off, and
            // without this the log has no way to say which of its entries
            // happened while anything was on screen — which is exactly the
            // distinction between a render that cost a frame and one that
            // cost a wakeup for nobody.
            RenderSignpost.mark("ScenePhaseChanged", "\(phase)")
            if phase == .active {
                model.sceneDidBecomeActive()
            } else if phase == .inactive || phase == .background {
                model.sceneWillResignActive()
            }
        }
    }
}
