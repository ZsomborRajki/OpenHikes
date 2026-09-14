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
        // The gate, rather than the raw phase: a scene returns through
        // `background → inactive → active`, and the two handlers below are
        // about becoming usable and about being put down, not about every
        // step between.
        //
        // Going to the background costs far more main thread than either
        // handler does — UIKit lays the hosting view out twice for the
        // app-switcher snapshot, under a `CA::Transaction::commit()`, with no
        // callback the app can bracket. Measured at 120 ms for a bare map and
        // 270 ms with the elevation chart up, and it is the system's rather
        // than the app's: the handlers here run in 1-2 ms.
        switch lifecycleGate.event(for: phase) {
        case .becameActive: sceneDidBecomeActive()
        case .willResignActive: sceneWillResignActive()
        case .redundant: break
        }
    }

    func sceneDidBecomeActive() {
        // Measured at under 0.02 ms, and that is the point: coming to the
        // foreground costs a main-thread turn of 100 ms or less against
        // backgrounding's 270, and none of either belongs to this handler.
        autoSaveController.sceneDidBecomeActive()
        if !AppLaunchEnvironment.isRunningTests {
            backgroundTracker.refreshBasemaps()
        }
        // Armed here and taken down on the way out, which is the whole of what
        // keeps the weather badge's movement feed from becoming a background
        // wake source: significant-change monitoring left running relaunches a
        // suspended app, and nothing this feed drives is on screen when the
        // app is not. See ``SignificantLocationFeed``.
        if AppLaunchEnvironment.usesLiveLocation {
            significantLocations.start()
        }
        hikeRecorder.sceneDidBecomeActive()
        // A walk left in a pocket through the night has no fix to notice it
        // by; coming back is the other moment it can.
        walkSession.endIfAbandoned()
        cloudSync.sceneDidBecomeActive()
        entitlement.sceneDidBecomeActive()
    }

    func sceneWillResignActive() {
        // This handler runs in 1-2 ms, against the ~300 ms the watchdog sees
        // on the way to the background. The rest is after it returns, in
        // UIKit's app-switcher snapshot, which the app has no callback inside.
        significantLocations.stop()
        hikeRecorder.sceneWillResignActive()
        // Backstop: a launch whose map never appeared — a failed store, an
        // error screen — would otherwise leave the extended launch task open
        // for the life of the process, and MetricKit reports nothing for a
        // measurement that never ends.
        LaunchMeasurement.finish()
        autoSaveController.sceneWillResignActive {
            try container.mainContext.save()
        }
    }
}
