//
//  OpenHikesModel+AutoPause.swift
//  OpenHikes
//
//  The two choices about the environment the composition root makes for
//  Auto-Pause: where a debug build keeps its evidence, and how long a stop
//  takes under UI automation. Apart from `OpenHikesModel+Composition.swift`
//  for that file's length.
//

import Foundation
import OpenHikesShared

extension OpenHikesModel {
    /// Where a `DEBUG` build writes down what its recordings were shown, so
    /// Auto-Pause's thresholds can be settled from walks that happened — see
    /// ``AutoPauseEvidence``. `nil` in a release build, and under tests.
    static func makeAutoPauseEvidence() -> (@Sendable (AutoPauseEvidence.Record) -> Void)? {
        #if DEBUG
        guard !AppLaunchEnvironment.isRunningTests, let file = AutoPauseEvidenceFile() else { return nil }
        return { record in file.append(record) }
        #else
        return nil
        #endif
    }

    /// The stop a UI-testing launch asked for, on the shipping rule
    /// otherwise — see ``AppLaunchEnvironment/autoPauseStopSeconds``.
    static func uiTestingAutoPausePolicy() -> AutoPausePolicy {
        var policy = AutoPausePolicy.standard
        if let seconds = AppLaunchEnvironment.autoPauseStopSeconds {
            policy.minimumStopSeconds = TimeInterval(seconds)
        }
        return policy
    }
}
