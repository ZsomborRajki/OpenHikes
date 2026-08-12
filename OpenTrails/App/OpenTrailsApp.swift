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

    @State private var model: OpenTrailsModel

    init() {
        #if DEBUG
        MainThreadWatchdog.start()
        #endif
        Task.detached {
            TileCache.shared.removeExpiredTiles()
        }

        // Constructed here, not lazily inside a view, because a background
        // relaunch (triggered by a significant-location-change event) runs
        // `init()` unconditionally but may never reach a view's `.task`/
        // `.onAppear` — the location manager has to already be live and
        // delegated by the time this returns, or the relaunch's one pending
        // location event has nothing to deliver to.
        _model = State(initialValue: OpenTrailsModel())
    }

    var body: some Scene {
        WindowGroup {
            OpenTrailsView()
                .environment(model)
                .ignoresSafeArea()
        }
        .modelContainer(model.container)
        // The widget's basemaps need the network to render, so a trail
        // selected offline (or during a background relaunch) can end up
        // without them. Re-checking on every foreground is how that heals;
        // it's a bounds comparison and no work when they're already right.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneDidBecomeActive()
            } else if phase == .inactive || phase == .background {
                model.sceneWillResignActive()
            }
        }
    }
}
