//
//  OpenHikesWatchApp.swift
//  OpenHikesWatch
//
//  The watch app's entry point. One ``WatchModel``, built here and injected
//  through the environment, exactly as `OpenHikesApp` does on the phone.
//

import SwiftUI

@main
struct OpenHikesWatchApp: App {
    @State private var model = WatchModel()

    @Environment(\.scenePhase)
    private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                // `.task` rather than `init`, because activating a `WCSession`
                // asks the system for a delegate callback and there is nothing
                // to deliver it to until there is a scene.
                .task { model.start() }
                // Every time the app comes to the front, not only the first.
                // A hiker who opens it again after installing it is a hiker
                // already wondering why the list is empty, and this is the
                // cheapest moment to ask the phone again — see
                // ``WatchModel/askForLibraryIfEmpty()``.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.askForLibraryIfEmpty() }
                }
        }
    }
}
