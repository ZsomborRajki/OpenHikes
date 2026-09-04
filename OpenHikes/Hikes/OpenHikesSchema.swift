//
//  OpenHikesSchema.swift
//  OpenHikes
//
//  The durable SwiftData schema history and the only migration route the app
//  uses to open its paired stores.
//
//  The floor of this history is the oldest shape that was actually shipped,
//  not the current shape under an older number — even though a store matching
//  no listed version still opens today. That was measured rather than assumed:
//  SwiftData falls back to inferring a lightweight migration when nothing in
//  `schemas` matches the store on disk, so an inaccurate history does not
//  brick a launch. What it does instead is quieter and permanent. A version
//  that never existed is a version nothing can be tested against: the stage
//  below would be migrating *from* a shape no store was ever written by, so it
//  proves nothing about the stores that do exist, and the first stage that
//  needs custom code — one that has to move or reinterpret a column rather
//  than default it — would be written against that fiction and run against
//  real rows. The history is only worth the accuracy of its oldest entry.
//

import Foundation
import SwiftData

nonisolated protocol OpenHikesVersionedSchema: VersionedSchema {
    static var hikeModels: [any PersistentModel.Type] { get }
    /// Empty for a version that predates the sidecar store — see
    /// ``OpenHikesSchemaV1``. `ModelContainer.openHikes(schemaVersion:…)`
    /// reads it to decide whether there is a second configuration to open at
    /// all, because a store that did not exist yet cannot be described by an
    /// empty one.
    static var localStateModels: [any PersistentModel.Type] { get }
}

nonisolated extension OpenHikesVersionedSchema {
    static var models: [any PersistentModel.Type] { hikeModels + localStateModels }
}

/// The shape shipped before auto-save, auto-follow and recording drafts
/// existed: one store, with the offline tile manifest still a column on
/// `Hike`. There was no sidecar file at all, which is why
/// ``localStateModels`` is empty.
///
/// Frozen, and every type it names is frozen with it — including the value
/// types the columns encode. A version that reached for the *live*
/// `RouteCoordinate` or `OfflineDownloadRecord` would silently change shape
/// whenever those did, which is the one thing a schema history exists to
/// prevent: the stage below would then be migrating from a version no store on
/// disk was ever written by. Never edit this enum.
nonisolated enum OpenHikesSchemaV1: OpenHikesVersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var hikeModels: [any PersistentModel.Type] { [Hike.self] }
    static var localStateModels: [any PersistentModel.Type] { [] }

    /// A track point as this version encodes one. The optionals are what a
    /// point written before motion and provenance existed decodes to, so this
    /// copy reads every payload a V1-era store can hold.
    nonisolated struct RouteCoordinate: Codable, Hashable, Sendable {
        var latitude: Double
        var longitude: Double
        var elevation: Double?
        var timestamp: Date?
        var motion: String?
        var provenance: String?
    }

    /// One offline download as this version encodes one, back when the array
    /// of them was a column on `Hike`.
    nonisolated struct OfflineDownloadRecord: Codable, Hashable, Sendable {
        var providerID: String
        var scale: Double
        var maxZoom: Int
        var savedTileKeys: [String]
    }

    @Model
    final class Hike {
        var id = UUID()
        var title: String = ""
        var distanceMeters: Double = 0
        var date = Date.now
        var tintHex: String = "#34C759"
        var routeWidth: Double = 3
        var symbol: String = "figure.hiking"
        var route: [RouteCoordinate] = []
        var offlineDownloads: [OfflineDownloadRecord] = []
        var trackDescription: String?
        var author: String?
        var keywords: String?

        init(
            title: String,
            distanceMeters: Double,
            id: UUID = UUID(),
            date: Date = .now,
            route: [RouteCoordinate] = []
        ) {
            self.id = id
            self.title = title
            self.distanceMeters = distanceMeters
            self.date = date
            self.route = route
        }
    }
}

/// The current shape, and the first to be versioned explicitly: the columns
/// added since V1, and the device-local half split out into its own unmirrored
/// store — see ``HikeLocalState`` for why that split is load-bearing.
///
/// This is the live version, so it points at the live model types rather than
/// at nested copies. That is what makes "the app's schema" and "the newest
/// version in the history" the same thing by construction instead of by
/// diligence. Before changing the persisted shape again, freeze this version
/// the way ``OpenHikesSchemaV1`` is frozen — nested model copies, nested
/// copies of the value types they encode — then add V3 and its stage.
///
/// Walks were added to this version in place rather than as a V3: the
/// `HikeWalk` entity and the sidecar's `walkInProgress` column are both
/// additive, and at the time no install carried a V2 store worth migrating —
/// the mirrored container was reset alongside. A store written before them
/// still opens, through the lightweight migration SwiftData infers.
nonisolated enum OpenHikesSchemaV2: OpenHikesVersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var hikeModels: [any PersistentModel.Type] { [Hike.self, HikeWalk.self] }
    static var localStateModels: [any PersistentModel.Type] { [HikeLocalState.self] }
}

nonisolated enum OpenHikesMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [OpenHikesSchemaV1.self, OpenHikesSchemaV2.self]
    }

    /// Lightweight throughout. The columns V2 adds all carry inline
    /// declaration defaults for exactly this reason, and the one column V1 has
    /// that V2 does not — `Hike.offlineDownloads` — is dropped rather than
    /// carried into the sidecar store. A custom stage cannot move it there
    /// anyway: the two live in different stores, which is the whole point of
    /// the split, and tiles are re-fetchable by definition. The cost is a
    /// download; the alternative is a column naming *this* device's files
    /// inside a row that syncs.
    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: OpenHikesSchemaV1.self,
                toVersion: OpenHikesSchemaV2.self
            ),
        ]
    }
}
