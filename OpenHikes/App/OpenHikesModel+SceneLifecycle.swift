//
//  OpenHikesModel+SceneLifecycle.swift
//  OpenHikes
//
//  What the app does when it leaves the foreground and when it comes back.
//
//  Kept out of the model's own body so its length stays about the app's
//  dependencies rather than about the phases iOS reports. The rule for *which*
//  transitions count is not here either: ``SceneLifecycleGate`` is a pure value
//  type so it can be asserted directly, and this is only the routing.
//

import SwiftData
import SwiftUI

extension OpenHikesModel {
    func scenePhaseChanged(to phase: ScenePhase) {
        // Marked before either handler runs so the event file carries the
        // boundary itself. A hike is mostly spent with the screen off, and
        // without this the log has no way to say which of its entries
        // happened while anything was on screen — which is exactly the
        // distinction between a render that cost a frame and one that cost a
        // wakeup for nobody. Marked for every phase, including the ones the
        // gate drops, so the log still describes what iOS actually did.
        RenderSignpost.mark("ScenePhaseChanged", "\(phase)")
        switch lifecycleGate.event(for: phase) {
        case .becameActive: sceneDidBecomeActive()
        case .willResignActive: sceneWillResignActive()
        case .redundant: break
        }
    }

    func sceneDidBecomeActive() {
        autoSaveController.sceneDidBecomeActive()
        if !AppLaunchEnvironment.isRunningTests {
            backgroundTracker.refreshBasemaps()
        }
        hikeRecorder.sceneDidBecomeActive()
        cloudSync.sceneDidBecomeActive()
        entitlement.sceneDidBecomeActive()
    }

    func sceneWillResignActive() {
        hikeRecorder.sceneWillResignActive()
        // Backstop: a launch whose map never appeared — a failed store, an
        // error screen — would otherwise leave the extended launch task open
        // for the life of the process, and MetricKit reports nothing for a
        // measurement that never ends.
        LaunchMeasurement.finish()
        autoSaveController.sceneWillResignActive {
            try container.mainContext.save()
        }
        #if DEBUG
        // The last moment a measured run can count on: UI automation
        // backgrounds the app and only then terminates it, so this is what
        // gets the tail of the scenario onto disk.
        PerformanceLog.shared?.flush()
        #endif
    }
}
