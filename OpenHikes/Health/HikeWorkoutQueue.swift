//
//  HikeWorkoutQueue.swift
//  OpenHikes
//
//  One Health operation at a time for each hike, in the order they were
//  asked for.
//
//  Every path into Health fires its work off rather than awaiting it: the
//  recorder's export once the hike is saved, a walk from the watch, an edit's
//  replacement. Each is several calls with suspensions between them, so two
//  for one hike side by side interleave. A trim's workout still being written
//  when a revert has deleted it and written the original leaves Health
//  holding both, and Health cannot be read to notice. So an operation for a
//  hike starts only once every one asked for that hike before it has
//  finished.
//
//  One queue, the recorder's, beside the one writer every path shares (see
//  ``OpenHikesModel/makeWorkoutWriter()``). Kept per hike, so a write held up
//  by a slow store holds up nothing about any other hike.
//
//  A hike's deletion does not wait here: it asks Health at once, and a write
//  still under way when it does takes itself back — see
//  ``HikeWorkoutExport/write(_:with:filingInto:)``.
//

import Foundation

@MainActor
final class HikeWorkoutQueue {
    /// The last operation asked for a hike, and the ticket that tells it
    /// apart from one asked for after it.
    private struct Tail {
        let ticket: Int
        let task: Task<Void, Never>
    }

    private var tails: [UUID: Tail] = [:]
    private var lastTicket = 0

    /// Runs `operation` once every operation asked for `hikeID` before it has
    /// finished.
    ///
    /// - Returns: The task that runs it, for a caller that waits for it.
    @discardableResult func enqueue(
        for hikeID: UUID,
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = tails[hikeID]?.task
        lastTicket += 1
        let ticket = lastTicket
        let task = Task {
            await previous?.value
            await operation()
            if tails[hikeID]?.ticket == ticket { tails[hikeID] = nil }
        }
        tails[hikeID] = Tail(ticket: ticket, task: task)
        return task
    }
}
