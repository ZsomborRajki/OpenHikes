//
//  TrailDraftStore.swift
//  OpenHikes
//
//  Reading and writing the one ``TrailDraftRecord``.
//
//  Its own type rather than three calls spread through the controller,
//  because "there is exactly one draft row" is a rule and a rule wants one
//  place to live. Every write goes through ``save(waypoints:)``, which updates
//  the row that is there rather than inserting beside it.
//
//  A failed read or write is logged and swallowed, deliberately. What is at
//  stake is a convenience — coming back to a half-drawn line — and there is
//  nothing a hiker mid-draw could do about a store that refused, while an
//  alert over the map would interrupt the drawing to report that the drawing
//  may not survive being interrupted. The line itself is in ``TrailDraft`` and
//  is unaffected.
//
//  Swallowed is not the same as ignored. A read that threw is answered as a
//  failure rather than as an empty store, because the two differ by exactly
//  one thing: whether ``save(waypoints:)`` writes a second row beside the
//  first. See the note on it.
//

import Foundation
import os
import SwiftData

@MainActor
struct TrailDraftStore {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// The points of the stored draft, and empty when nothing has been drawn.
    ///
    /// Empty rather than an optional, and the two would say the same thing
    /// anyway: a row left behind by a cleared draft, no row at all, and a read
    /// that threw all mean *there is no drawing to come back to*, so answering
    /// one way for all three is what keeps the caller from having to know
    /// which of them it got.
    func load() -> [TrailWaypoint] {
        do {
            guard let record = try existingRecord() else { return [] }
            return record.waypoints.map { point in
                TrailWaypoint(latitude: point.latitude, longitude: point.longitude)
            }
        } catch {
            log("load", error)
            return []
        }
    }

    /// Writes the draft, replacing whatever was there.
    ///
    /// **A read that failed is not an empty store**, and this writes nothing
    /// when it cannot tell the two apart. Treating a thrown fetch as "no row"
    /// is what takes the branch below and inserts a *second* row beside the
    /// one that is already there — breaking the single rule this type exists
    /// to hold, and leaving ``load()`` to answer with whichever of the two an
    /// unsorted fetch limit hands back. Losing one write of a convenience is
    /// the cheaper failure, and it is the same one a refused `context.save()`
    /// already takes.
    func save(waypoints: [TrailWaypoint]) {
        let points = waypoints.map(\.routeCoordinate)
        do {
            if let record = try existingRecord() {
                record.waypoints = points
                record.updatedAt = .now
            } else {
                context.insert(
                    TrailDraftRecord(waypoints: points, updatedAt: .now)
                )
            }
        } catch {
            log("save", error)
            return
        }
        commit("save")
    }

    /// Throws the draft away, which is what Cancel and a completed Save both
    /// do. Deleting the row rather than emptying it: a draft nobody is drawing
    /// should leave nothing behind.
    func clear() {
        do {
            guard let record = try existingRecord() else { return }
            context.delete(record)
        } catch {
            log("clear", error)
            return
        }
        commit("clear")
    }

    /// The one row, or none.
    ///
    /// A fetch limit rather than a uniqueness constraint, for the reason
    /// ``TrailDraftRecord`` gives. If a second row ever existed — nothing here
    /// writes one — this answers with the same one every time rather than
    /// alternating, since a `FetchDescriptor` with no sort is stable for a
    /// store nothing else is writing to.
    ///
    /// Throwing rather than answering `nil`, because "the fetch failed" and
    /// "there is no draft" are the same word to a caller that cannot tell them
    /// apart, and one of the three callers writes a row on the second — see
    /// ``save(waypoints:)``.
    private func existingRecord() throws -> TrailDraftRecord? {
        var descriptor = FetchDescriptor<TrailDraftRecord>()
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func commit(_ operation: String) {
        do {
            try context.save()
        } catch {
            log(operation, error)
        }
    }

    private func log(_ operation: String, _ error: any Error) {
        Self.logger.error(
            """
            A trail draft could not be read or written (\(operation, privacy: .public)): \
            \(error.localizedDescription, privacy: .public)
            """
        )
    }
}
