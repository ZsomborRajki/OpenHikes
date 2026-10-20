//
//  TrailDraftSaveTarget.swift
//  OpenHikes
//
//  Where the maker's Save writes the drawing: into the hike *Edit Route*
//  opened, or into a new one.
//
//  **A read that failed is not a deleted hike.** An edit whose hike has gone
//  is saved as a new trail, because the drawing is still the hiker's work and
//  there is nothing left to write it into. But that branch inserts a row, so
//  it is taken only on a fetch that answered and found nothing: a fetch that
//  threw says nothing about whether the hike is there, and a hiker who named
//  the "new" trail would end up with a copy beside the original the edit was
//  meant for. The same distinction ``TrailDraftStore``, ``WatchWalkImport``
//  and ``CommunityImport`` each keep at their own insert.
//

import Foundation
import OpenHikesData
import os
import SwiftData

/// What Save does with the drawing, decided before anything is written.
enum TrailDraftSaveTarget {
    /// Write back into the hike being edited, which is still in the store.
    case edit(Hike)
    /// Ask for a name and save a new trail: nothing was being edited, or the
    /// hike that was is positively gone.
    case newTrail
    /// The store could not say whether the hike being edited is there.
    /// Nothing is written, and the drawing waits for the next Save.
    case refused(TrailDraftRefusal)

    nonisolated private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "TrailDraft"
    )

    /// Resolves the maker's `editingHikeID` against the store.
    ///
    /// - Parameter fetch: The seam the read goes through, for the reason
    ///   ``TrailDraftSave/hike(from:named:into:madeOn:heights:keepingPlaces:save:)``
    ///   takes its `save` as one: nothing makes a `ModelContext` throw on
    ///   demand, and the failing read is the branch whose whole point is what
    ///   it does *not* do — insert a second copy of the trail.
    static func resolve(
        editing id: UUID?,
        in context: ModelContext,
        fetch: (UUID, ModelContext) throws -> Hike? = Self.hike(withID:in:)
    ) -> Self {
        guard let id else { return .newTrail }
        do {
            guard let hike = try fetch(id, context) else { return .newTrail }
            return .edit(hike)
        } catch {
            logger.error(
                """
                The trail being edited could not be read: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return .refused(.notSaved)
        }
    }

    /// The hike with this id, `nil` when the store has none, and a throw when
    /// the store could not be read — the three answers ``resolve(editing:in:fetch:)``
    /// keeps apart.
    nonisolated static func hike(withID id: UUID, in context: ModelContext) throws -> Hike? {
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
