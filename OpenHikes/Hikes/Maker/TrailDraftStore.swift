//
//  TrailDraftStore.swift
//  OpenHikes
//
//  Reading and writing the one ``TrailDraftRecord``.
//
//  Its own type rather than three calls spread through the controller,
//  because "there is exactly one draft row" is a rule and a rule wants one
//  place to live. Every write goes through ``save(name:waypoints:)``, which
//  updates the row that is there rather than inserting beside it.
//
//  A failed write is logged and swallowed, deliberately. What is at stake is
//  a convenience — coming back to a half-drawn line — and there is nothing a
//  hiker mid-draw could do about a store that refused, while an alert over the
//  map would interrupt the drawing to report that the drawing may not survive
//  being interrupted. The line itself is in ``TrailDraft`` and is unaffected.
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

    /// The stored draft, or `nil` when nothing has been drawn.
    ///
    /// An empty point list reads as nothing rather than as an empty draft: a
    /// row left behind by a cleared draft and no row at all mean the same
    /// thing to the maker, and answering `nil` for both is what keeps the
    /// caller from having to know which one it got.
    func load() -> (name: String, waypoints: [TrailWaypoint])? {
        guard let record = existingRecord(), !record.waypoints.isEmpty else { return nil }
        return (
            record.name,
            record.waypoints.map { point in
                TrailWaypoint(latitude: point.latitude, longitude: point.longitude)
            }
        )
    }

    /// Writes the draft, replacing whatever was there.
    func save(name: String, waypoints: [TrailWaypoint]) {
        let points = waypoints.map(\.routeCoordinate)
        if let record = existingRecord() {
            record.name = name
            record.waypoints = points
            record.updatedAt = .now
        } else {
            context.insert(
                TrailDraftRecord(name: name, waypoints: points, updatedAt: .now)
            )
        }
        commit("save")
    }

    /// Throws the draft away, which is what Cancel and a completed Save both
    /// do. Deleting the row rather than emptying it: a draft nobody is drawing
    /// should leave nothing behind.
    func clear() {
        guard let record = existingRecord() else { return }
        context.delete(record)
        commit("clear")
    }

    /// The one row, or none.
    ///
    /// A fetch limit rather than a uniqueness constraint, for the reason
    /// ``TrailDraftRecord`` gives. If a second row ever existed — nothing here
    /// writes one — this answers with the same one every time rather than
    /// alternating, since a `FetchDescriptor` with no sort is stable for a
    /// store nothing else is writing to.
    private func existingRecord() -> TrailDraftRecord? {
        var descriptor = FetchDescriptor<TrailDraftRecord>()
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func commit(_ operation: String) {
        do {
            try context.save()
        } catch {
            Self.logger.error(
                """
                A trail draft could not be written (\(operation, privacy: .public)): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
