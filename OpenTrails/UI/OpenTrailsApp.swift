//
//  OpenTrailsApp.swift
//  OpenTrails
//
//  Created by Zsombor Rajki on 2026. 06. 18..
//

import SwiftUI
import SwiftData

@main
struct OpenTrailsApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    private let backgroundTracker: BackgroundTrailTracker
    private let autoSaveController: AutoSaveController

    init() {
        #if DEBUG
        MainThreadWatchdog.start()
        #endif
        Task.detached {
            TileCache.shared.removeExpiredTiles()
        }
        // Built explicitly (rather than via the `.modelContainer(for:)` scene
        // modifier) so `backgroundTracker` — which needs its own SwiftData
        // access to look up the tracked hike on a background relaunch — can
        // share the same container/store as the view hierarchy below.
        let container = try! ModelContainer(for: Hike.self)
        self.container = container
        // Constructed here, not lazily inside a view, because a background
        // relaunch (triggered by a significant-location-change event) runs
        // `init()` unconditionally but may never reach a view's `.task`/
        // `.onAppear` — the location manager has to already be live and
        // delegated by the time this returns, or the relaunch's one pending
        // location event has nothing to deliver to.
        self.backgroundTracker = BackgroundTrailTracker(container: container)
        self.autoSaveController = AutoSaveController()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(backgroundTracker: backgroundTracker, autoSaveController: autoSaveController)
                .ignoresSafeArea()
        }
        .modelContainer(container)
        // The widget's basemaps need the network to render, so a trail
        // selected offline (or during a background relaunch) can end up
        // without them. Re-checking on every foreground is how that heals;
        // it's a bounds comparison and no work when they're already right.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                autoSaveController.sceneDidBecomeActive()
                backgroundTracker.refreshBasemaps()
            } else if phase == .inactive || phase == .background {
                autoSaveController.sceneWillResignActive {
                    try container.mainContext.save()
                }
            }
        }
    }
}
