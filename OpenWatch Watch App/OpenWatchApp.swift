//
//  OpenWatchApp.swift
//  OpenWatch Watch App
//
//  Created by Zsombor Rajki on 2026. 08. 10..
//

import SwiftUI

@main
struct OpenWatch_Watch_AppApp: App {
    private let bridge: WatchConnectivityBridge

    init() {
        // Constructed here, not lazily inside a view, for the same reason as
        // the phone app's BackgroundTrailTracker: WatchConnectivity can wake
        // this app in the background to deliver a new snapshot, and that
        // relies on the session already being activated by the time it does.
        self.bridge = WatchConnectivityBridge()
    }

    var body: some Scene {
        WindowGroup {
            TrailWatchView(bridge: bridge)
        }
    }
}
