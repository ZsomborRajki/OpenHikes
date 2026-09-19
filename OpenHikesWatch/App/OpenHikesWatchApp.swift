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

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                // `.task` rather than `init`, because activating a `WCSession`
                // asks the system for a delegate callback and there is nothing
                // to deliver it to until there is a scene.
                .task { model.start() }
        }
    }
}
