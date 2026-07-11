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
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
        }
        .modelContainer(for: Hike.self)
    }
}
