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
        measuringTurn {
            switch lifecycleGate.event(for: phase) {
            case .becameActive: sceneDidBecomeActive()
            case .willResignActive: sceneWillResignActive()
            case .redundant: break
            }
        }
    }

    /// Runs `body`, and times the whole main-thread turn it belongs to — not
    /// just `body` itself.
    ///
    /// The span closes on the next main-queue drain, which is a different
    /// run-loop stage from the scene-settings callout this is called inside.
    /// So it covers everything the main thread goes on to do before it is free
    /// again: the app's own handler, the SwiftUI pass the phase change drives,
    /// and — the part that matters — the app-switcher snapshots UIKit takes
    /// after the handler returns.
    ///
    /// That last stretch is why this exists. `docs/PERFORMANCE.md` carried a
    /// ~300 ms window "with no mark in it at all" for as long as the harness
    /// has been measuring, because nothing running in it was the app's to mark
    /// at all: `-[UIApplication _performSnapshotsWithAction:forScene:]` lays
    /// the hosting view out twice, under a `CA::Transaction::commit()`, with
    /// no callback the app can bracket. A turn is bracketable even when
    /// its contents are not, and ``PerformanceUITests`` budgets this rather
    /// than a stall that has to be caught in the act to be seen at all.
    ///
    /// The ``SceneResignActive`` span inside it is what separates the app's
    /// share from the system's: the difference between the two is UIKit's.
    private func measuringTurn(_ body: () -> Void) {
        #if DEBUG
        let turn = RenderSignpost.beginInterval("ScenePhaseTurn")
        body()
        DispatchQueue.main.async { RenderSignpost.endInterval("ScenePhaseTurn", turn) }
        #else
        body()
        #endif
    }

    func sceneDidBecomeActive() {
        // The counterpart to ``SceneResignActive``, so the way back in is
        // accounted for on the same terms as the way out. It has never read
        // more than 0.02 ms, and that is the point: coming to the foreground
        // costs a turn of 100 ms or less against backgrounding's 273, and none
        // of either belongs to these handlers.
        let becomeActive = RenderSignpost.beginInterval("SceneDidBecomeActive")
        defer { RenderSignpost.endInterval("SceneDidBecomeActive", becomeActive) }
        autoSaveController.sceneDidBecomeActive()
        if !AppLaunchEnvironment.isRunningTests {
            backgroundTracker.refreshBasemaps()
        }
        hikeRecorder.sceneDidBecomeActive()
        cloudSync.sceneDidBecomeActive()
        entitlement.sceneDidBecomeActive()
    }

    func sceneWillResignActive() {
        // Bracketed whole, and the save inside it bracketed again, because the
        // ~300 ms the watchdog sees on the way to the background falls in a
        // window with no mark in it — so the first thing that has to be
        // settled is whether it is inside this handler at all. A span that
        // reads a millisecond while the stall stands says the cost is after
        // the app's own resign work, in what UIKit does next.
        let resign = RenderSignpost.beginInterval("SceneResignActive")
        defer { RenderSignpost.endInterval("SceneResignActive", resign) }
        hikeRecorder.sceneWillResignActive()
        // Backstop: a launch whose map never appeared — a failed store, an
        // error screen — would otherwise leave the extended launch task open
        // for the life of the process, and MetricKit reports nothing for a
        // measurement that never ends.
        LaunchMeasurement.finish()
        autoSaveController.sceneWillResignActive {
            try RenderSignpost.interval("SceneResignSave") {
                try container.mainContext.save()
            }
        }
        #if DEBUG
        // The last moment a measured run can count on: UI automation
        // backgrounds the app and only then terminates it, so this is what
        // gets the tail of the scenario onto disk.
        PerformanceLog.shared?.flush()
        #endif
    }
}
