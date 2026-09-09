//
//  OpenHikesSchemaV2.swift
//  OpenHikes
//
//  Frozen before recording ownership was added to the local store. Every
//  persisted value type is copied too, so later edits cannot change V2.
//  Never edit this version after release.
//

import Foundation
import SwiftData

nonisolated enum OpenHikesSchemaV2: OpenHikesVersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var hikeModels: [any PersistentModel.Type] { [Hike.self, HikeWalk.self] }
    static var localStateModels: [any PersistentModel.Type] { [HikeLocalState.self] }

    nonisolated enum RouteMotion: String, Codable, Hashable, Sendable {
        case nonPedestrian = "nonPedestrian"
    }

    nonisolated enum RouteProvenance: String, Codable, Hashable, Sendable {
        case inferred = "inferred"
    }

    nonisolated enum RouteBoundary: String, Codable, Hashable, Sendable {
        case paused = "paused"
    }

    nonisolated struct RouteCoordinate: Codable, Hashable, Sendable {
        var latitude: Double
        var longitude: Double
        var elevation: Double?
        var timestamp: Date?
        var motion: RouteMotion?
        var provenance: RouteProvenance?
        var boundary: RouteBoundary?
    }

    nonisolated struct OfflineDownloadRecord: Codable, Hashable, Sendable {
        var providerID: String
        var maxZoom: Int
        var savedTileKeys: [String]
        var scale: Double
    }

    nonisolated enum PhotoMatchEvidence: String, Codable, Hashable, Sendable {
        case place = "place"
        case time = "time"
        case timeAndPlace = "timeAndPlace"
    }

    nonisolated struct HikePhoto: Codable, Hashable, Sendable {
        var id: UUID
        var capturedAt: Date
        var pathExtension: String
        var latitude: Double?
        var longitude: Double?
        var assetLocalIdentifier: String?
        var matchEvidence: PhotoMatchEvidence?
    }

    nonisolated struct TrailWalkCoverage: Codable, Equatable, Sendable {
        var intervals: [Double] = []
        var furthestDistanceMeters: Double = 0
        var lastMatchedDistance: Double?
    }

    nonisolated struct TrailWalkRecord: Codable, Equatable, Sendable {
        var hikeID: UUID
        var startedAt: Date
        var coverage: TrailWalkCoverage
        var bankedActiveSeconds: TimeInterval
        var phaseID: String
        var phaseChangedAt: Date
        var lastMatchedAt: Date?
        var lastFollowedDistanceMeters: Double?
        var routeDistanceMeters: Double
    }

    @Model
    final class Hike {
        #Index<Hike>([\.id], [\.date], [\.isRecording])

        var id = UUID()
        var title: String = ""
        var distanceMeters: Double = 0
        var date = Date.distantPast
        var tintHex: String = "#34C759"
        var routeWidth: Double = 3
        var routeLinePatternID: String = "directional"
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
        // swiftlint:disable discouraged_optional_collection
        @Relationship(deleteRule: .cascade, inverse: \HikeWalk.hike)
        var walks: [HikeWalk]?
        // swiftlint:enable discouraged_optional_collection
        @Transient var cachedLocalState: HikeLocalState?

        init(id: UUID, title: String) {
            self.id = id
            self.title = title
        }
    }

    @Model
    final class HikeWalk {
        #Index<HikeWalk>([\.id], [\.hikeID], [\.startedAt])

        var id = UUID()
        var hikeID = UUID()
        var hike: Hike?
        var startedAt = Date.distantPast
        var endedAt = Date.distantPast
        var activeSeconds: Double = 0
        var coveredIntervals: [Double] = []
        var furthestDistanceMeters: Double = 0
        var routeDistanceMeters: Double = 0
        var endReasonID: String = "ended"

        init(hikeID: UUID) {
            self.hikeID = hikeID
        }
    }

    @Model
    final class HikeLocalState {
        #Index<HikeLocalState>([\.hikeID])

        var hikeID = UUID()
        var offlineDownloads: [OfflineDownloadRecord] = []
        var autoSavedTileKeys: [String] = []
        var autoSaveTilesEnabled: Bool = true
        var walkInProgress: TrailWalkRecord?

        init(hikeID: UUID) {
            self.hikeID = hikeID
        }
    }
}
