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

    /// Writes `request` and files the workout's identifier against its hike —
    /// or, when the hike was deleted while Health was answering, takes the
    /// workout straight back out.
    ///
    /// Logs rather than throws, because every caller has already saved the
    /// hike and there is nothing to report: a refused or failed write leaves
    /// no workout behind, and a hike Health would not take is still a hike.
    ///
    /// The owner is looked up *after* the write, because the write suspends
    /// for as long as HealthKit takes, and a hike can be deleted in that
    /// window. ``HikeDeletion`` removes only the workouts already filed when
    /// it runs, and this one has not been filed yet — so filing it anyway
    /// would put a sidecar back for a hike that is gone and leave a workout
    /// in Health that nothing will ever remove.
    static func write(
        _ request: HikeWorkoutRequest,
        with writer: any HikeWorkoutWriting,
        filingInto container: ModelContainer
    ) async {
        let context = container.mainContext
        let workoutID: UUID
        do {
            workoutID = try await writer.write(request)
        } catch {
            logger.error(
                """
                Health export failed for \(request.hikeID, privacy: .private): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return
        }
        let hikeID = request.hikeID
        let isGone = hikeIsGone {
            var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
            descriptor.fetchLimit = 1
            return try context.fetchCount(descriptor)
        }
        if isGone {
            await withdraw(workoutID, of: hikeID, from: writer)
            return
        }
        do {
            // Filed against the row only once the workout exists, so a
            // stored identifier always names something — see
            // ``HikeLocalState/healthWorkoutID``.
            let state = HikeLocalState.forHike(hikeID, in: context)
            state.healthWorkoutID = workoutID
            try context.save()
        } catch {
            logger.error(
                """
                Health export for \(hikeID, privacy: .private) was not filed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    /// Whether the store *answered* that the hike is no longer there.
    ///
    /// A fetch that failed is not that answer. It reads as "still here", so
    /// the identifier is filed exactly as it would have been: if the hike does
    /// exist — overwhelmingly the likelier case — its later deletion finds the
    /// workout and removes it; taking the workout out now instead would
    /// delete a walk from Health that is still in the list.
    ///
    /// - Parameter count: How many hikes carry the id, handed in because
    ///   nothing makes a `ModelContext` throw on demand, and the branch worth
    ///   pinning is the failing one.
    static func hikeIsGone(counting count: () throws -> Int) -> Bool {
        do {
            return try count() == 0
        } catch {
            logger.error(
                """
                Could not tell whether an exported hike still exists: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return false
        }
    }

    /// Takes a workout out of Health whose hike was deleted while it was
    /// being written. Awaited rather than fired off, because the caller is
    /// already a task of its own and has nothing else left to do.
    private static func withdraw(
        _ workoutID: UUID,
        of hikeID: UUID,
        from writer: any HikeWorkoutWriting
    ) async {
        do {
            try await writer.delete(workoutID: workoutID)
        } catch {
            logger.error(
                """
                Health kept a workout whose hike \(hikeID, privacy: .private) was deleted \
                during its export: \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
