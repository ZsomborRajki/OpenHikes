//
//  HikeWorkoutExport.swift
//  OpenHikes
//
//  What every path into Health shares: whether the hiker asked for it, and
//  what is kept once the workout exists.
//
//  Two paths write a workout — a recording this phone finished, in
//  `HikeRecorder`, and a walk the watch recorded and handed over, in
//  ``WatchWalkHealthExport``. They build their requests from different
//  sources, and nothing else about them may differ: a switch read one way here
//  and another way there is a walk written to Health for a hiker who turned
//  it off.
//

import Foundation
import OpenHikesData
import os
import SwiftData

@MainActor
enum HikeWorkoutExport {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Health")

    /// The hiker's switch, read at each export rather than captured, so
    /// turning it off between one hike and the next takes effect on the next
    /// one.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: SettingsKey.savesHikesToHealth) as? Bool
            ?? SettingsDefault.savesHikesToHealth
    }

    /// Writes `request` and files the workout's identifier against its hike.
    ///
    /// Logs rather than throws, because every caller has already saved the
    /// hike and there is nothing to report: a refused or failed write leaves
    /// no workout behind, and a hike Health would not take is still a hike.
    static func write(
        _ request: HikeWorkoutRequest,
        with writer: any HikeWorkoutWriting,
        filingInto container: ModelContainer
    ) async {
        do {
            let workoutID = try await writer.write(request)
            // Filed against the row only once the workout exists, so a
            // stored identifier always names something — see
            // ``HikeLocalState/healthWorkoutID``.
            let state = HikeLocalState.forHike(request.hikeID, in: container.mainContext)
            state.healthWorkoutID = workoutID
            try container.mainContext.save()
        } catch {
            logger.error(
                """
                Health export failed for \(request.hikeID, privacy: .private): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
