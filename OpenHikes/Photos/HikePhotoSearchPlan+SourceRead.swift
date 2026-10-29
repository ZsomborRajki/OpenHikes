//
//  HikePhotoSearchPlan+SourceRead.swift
//  OpenHikes
//
//  Where both photo searches read what their plan is built from.
//
//  Find Photos and the picker each build their ``HikePhotoSearchPlan`` off
//  the main actor — ``PhotoDiscoveryWork`` (#1119) and ``PickedPhotoWork``
//  (#1189) — but both used to read its ``HikePhotoSearchPlan/Source`` on the
//  main actor first, and that read is route-sized as well. `route` is
//  external storage, decoded whole the first time a context reads it, and a
//  hike with finished walks hashes every point of it again to tell the walks
//  along its line from the rest — see ``Hike/walkPhotoTimelines``. On a long
//  recording with walks along it, that was a main-thread stall of more than
//  a frame before either search had left the main actor (#1215).
//
//  So what crosses is the row's identifier and its container, and the read
//  runs in a context of its own off the main actor, the way
//  ``SharedHikeCatalogPublisher`` reads a pinned trail (#1025). The context
//  and the `Hike` it vends are made, read and dropped inside one call, and
//  only the source's values leave it.
//
//  A context of its own reads the store, and the store holds a hike the way
//  the hike's own context does only once that context has saved it. Every
//  writer of a route or a walk saves at once, so in the app that is the
//  ordinary case. A hike holding edits the store has not had yet — one never
//  saved, or one with a walk inserted under it and not yet written — is read
//  where those edits are, on its own actor, as both searches read every hike
//  before: route-sized on the main thread again, and the one answer that
//  cannot leave the edit out.
//

import Foundation
import OpenHikesData
import SwiftData

nonisolated extension HikePhotoSearchPlan {
    /// What a search reads its ``Source`` from: a hike named on its own
    /// actor, so that the reading itself can happen off it.
    enum SourceRead: Sendable {
        /// A row its context has saved, fetched by its identifier into a
        /// context of the read's own.
        case saved(PersistentIdentifier, in: ModelContainer)
        /// The values themselves, read off a row with edits its store has not
        /// had yet.
        case unsaved(Source)

        /// Names `hike` for a read: from the store when its context has
        /// written every edit to it, and read here, on the spot, when it has
        /// not.
        ///
        /// The hike's own flag rather than its context's. A walk is inserted
        /// under a hike through the relationship, which is an edit to the hike
        /// as well, and a walk once written is never edited again, so the
        /// hike's flag already answers for its walks. The context's would send
        /// a search back to the main actor for a pending edit to any other row.
        init(_ hike: Hike) {
            if !hike.hasChanges, let container = hike.modelContext?.container {
                self = .saved(hike.persistentModelID, in: container)
            } else {
                self = .unsaved(hike.photoSearchSource)
            }
        }

        /// The values this read names. A saved row is fetched through `fetch`
        /// into a context made here and dropped on return.
        ///
        /// `nil` for a saved row the store no longer holds, such as a hike
        /// deleted on another device that this one has not merged yet, or for
        /// one it cannot read. Neither has anything to search.
        func source(fetch: (ModelContext, PersistentIdentifier) throws -> Hike?) -> Source? {
            switch self {
            case let .saved(id, container):
                guard let hike = try? fetch(ModelContext(container), id) else { return nil }
                return hike.photoSearchSource
            case let .unsaved(source):
                return source
            }
        }

        /// The store's own answer for ``source(fetch:)``: the one row, if it
        /// is still there.
        ///
        /// By its persistent identifier rather than by `Hike.id`, because the
        /// identifier names the very row the caller's context holds, and a
        /// column with no uniqueness constraint cannot promise to.
        static func fetchHike(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
            var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.persistentModelID == id })
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }
    }
}
