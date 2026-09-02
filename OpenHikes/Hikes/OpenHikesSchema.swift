//
//  OpenHikesSchema.swift
//  OpenHikes
//
//  The durable SwiftData schema history and the only migration route the app
//  uses to open its paired stores.
//

import Foundation
import SwiftData

nonisolated protocol OpenHikesVersionedSchema: VersionedSchema {
    static var hikeModels: [any PersistentModel.Type] { get }
    static var localStateModels: [any PersistentModel.Type] { get }
}

nonisolated extension OpenHikesVersionedSchema {
    static var models: [any PersistentModel.Type] { hikeModels + localStateModels }
}

/// The last unversioned schema shipped by the app, frozen here so changing the
/// live model types cannot silently rewrite history. Both stores are present:
/// their rows join by `hikeID`, never by a cross-store relationship.
nonisolated enum OpenHikesSchemaV1: OpenHikesVersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var hikeModels: [any PersistentModel.Type] { [Hike.self] }
    static var localStateModels: [any PersistentModel.Type] { [HikeLocalState.self] }

    @Model
    final class Hike {
        #Index<Hike>([\.id], [\.date], [\.isRecording])

        var id = UUID()
        var title: String = ""
        var distanceMeters: Double = 0
        var date = Date.distantPast
        var tintHex: String = "#34C759"
        var routeWidth: Double = 3
        var routeLinePatternID: String = RouteLinePattern.default.rawValue
        var symbol: String = "figure.hiking"
        @Attribute(.externalStorage)
        var route: [RouteCoordinate] = []
        var customName: String?
        @Attribute(.externalStorage)
        var rawRoute: [RouteCoordinate] = []
        var isRecording: Bool = false
        var autoFollowEnabled: Bool = true
        var trackDescription: String?
        var author: String?
        var keywords: String?
        var surfaceMetersByCategory: [String: Double] = [:]
        var difficultyMetersByGrade: [String: Double] = [:]
        var photos: [HikePhoto] = []
        @Transient var cachedLocalState: HikeLocalState?

        init(
            id: UUID,
            title: String,
            distanceMeters: Double,
            date: Date,
            route: [RouteCoordinate]
        ) {
            self.id = id
            self.title = title
            self.distanceMeters = distanceMeters
            self.date = date
            self.route = route
        }
    }

    @Model
    final class HikeLocalState {
        #Index<HikeLocalState>([\.hikeID])

        var hikeID = UUID()
        var offlineDownloads: [OfflineDownloadRecord] = []
        var autoSavedTileKeys: [String] = []
        var autoSaveTilesEnabled: Bool = true

        init(hikeID: UUID) {
            self.hikeID = hikeID
        }
    }
}

/// Version two adopts explicit schema versioning. Its storage shape is
/// intentionally unchanged from version one: the migration stamps existing
/// stores with a durable version boundary without altering user data. This is
/// the live version; freeze its models as nested copies before adding V3.
nonisolated enum OpenHikesSchemaV2: OpenHikesVersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var hikeModels: [any PersistentModel.Type] { [Hike.self] }
    static var localStateModels: [any PersistentModel.Type] { [HikeLocalState.self] }
}

nonisolated enum OpenHikesMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [OpenHikesSchemaV1.self, OpenHikesSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: OpenHikesSchemaV1.self,
                toVersion: OpenHikesSchemaV2.self
            ),
        ]
    }
}
