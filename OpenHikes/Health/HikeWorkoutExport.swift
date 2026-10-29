//
//  HikeWorkoutExport.swift
//  OpenHikes
//
//  What every path into Health shares: whether the hiker asked for it, and
//  the mark that lets the hike's deletion take the write back.
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

    /// Writes `request`, marking its hike as written to Health before Health
    /// hears anything — and, when the hike was deleted while Health was
    /// answering, takes the write straight back out.
    ///
    /// Logs rather than throws, because every caller has already saved the
    /// hike and there is nothing to report: a hike Health would not take is
    /// still a hike.
    ///
    /// **Marked first** (``HikeLocalState/wroteToHealth``). A write can leave
    /// something in Health on every way out of it: a workout a locked phone
    /// saved without handing it back, a sample a failed write could not take
    /// back, a write this process never came back to finish. Health cannot be
    /// read to find any of them afterwards. Everything the write saves
    /// carries the hike's identifier, so a deletion only needs to know
    /// whether to ask, and marking the hike before the first call is what
    /// makes the answer yes on every one of those paths. A hike that cannot be
    /// marked is not written: that write could leave Health holding a walk
    /// nothing would ever take back.
    ///
    /// **Looked up on both sides of the write.** A hike already gone gets no
    /// write and no mark, because marking it would put a sidecar back for a
    /// hike that is gone. And the write suspends for as long as HealthKit
    /// takes, so a hike can be deleted in that window. ``HikeDeletion`` asks
    /// Health as the deletion commits, which can be before this write's
    /// objects exist, so a hike found gone once Health answers has its write
    /// taken back here as well.
    static func write(
        _ request: HikeWorkoutRequest,
        with writer: any HikeWorkoutWriting,
        filingInto container: ModelContainer
    ) async {
        let context = container.mainContext
        let hikeID = request.hikeID
        let countHikes = {
            var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
            descriptor.fetchLimit = 1
            return try context.fetchCount(descriptor)
        }
        if hikeIsGone(counting: countHikes) { return }
        do {
            HikeLocalState.forHike(hikeID, in: context).wroteToHealth = true
            try context.save()
        } catch {
            logger.error(
                """
                Health export for \(hikeID, privacy: .private) was not started, because \
                its hike could not be marked: \(error.localizedDescription, privacy: .public)
                """
            )
            return
        }
        do {
            try await writer.write(request)
        } catch {
            logger.error(
                """
                Health export failed for \(hikeID, privacy: .private): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        if hikeIsGone(counting: countHikes) {
            await withdraw(hikeID, from: writer)
        }
    }

    /// Whether the store *answered* that the hike is no longer there.
    ///
    /// A fetch that failed is not that answer. It reads as "still here", so
    /// the hike is marked and written, and its write is kept, exactly as they
    /// would have been: if the hike does exist — overwhelmingly the likelier
    /// case — its later deletion takes the write back; taking it back now
    /// instead would delete a walk from Health that is still in the list.
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

    /// Takes a write out of Health whose hike was deleted while it was being
    /// written. Awaited rather than fired off, because the caller is already
    /// a task of its own and has nothing else left to do.
    private static func withdraw(_ hikeID: UUID, from writer: any HikeWorkoutWriting) async {
        do {
            try await writer.deleteWorkout(of: hikeID)
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
