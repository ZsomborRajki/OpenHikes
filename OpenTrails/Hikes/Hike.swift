//
//  Hike.swift
//  OpenTrails
//
//  A recorded or imported hike, persisted with SwiftData and backing the Hikes list.
//

import Foundation
import SwiftData

@Model
final class Hike {
    /// Stable identity, also used to key the route drawn on the map.
    var id: UUID
    var title: String
    /// Total route length, in meters.
    var distanceMeters: Double
    /// Activity date — the GPX start time when available, otherwise the import date.
    var date: Date
    /// Route tint, stored as "#RRGGBB" or "#RRGGBBAA". The alpha is used only for
    /// the map polyline; other UI reads ``tintOpaque``.
    var tintHex: String
    /// Map polyline width, in points.
    var routeWidth: Double
    /// How the map draws this route's line — see ``RouteLinePattern``. Stored
    /// as its stable string id (like ``tintHex``) rather than as an enum, so an
    /// unrecognised value degrades to the default instead of failing to decode.
    ///
    /// The inline default is required for SwiftData lightweight migration: a
    /// store written before this column existed has to backfill it.
    var routeLinePatternID: String = RouteLinePattern.default.rawValue
    /// SF Symbol shown in the row's colored circle.
    var symbol: String
    /// Ordered track points making up the route.
    var route: [RouteCoordinate]
    /// A user-chosen name that overrides the GPS/import-derived ``title``.
    /// `nil` means no override is set and the original title is displayed.
    ///
    /// The inline `= nil` default is required for SwiftData lightweight
    /// migration so existing stores can backfill the new optional column.
    var customName: String?

    /// The unmatched GPS trace when trail matching moved a recorded route.
    /// Imported hikes and recordings that stayed raw leave this empty.
    ///
    /// The inline default is required for lightweight migration of existing
    /// stores, just like the defaults on the auto-save fields below.
    var rawRoute: [RouteCoordinate] = []
    /// True while this row is the durable draft owned by an active recording.
    /// The route stays empty until Stop finalizes the draft in place.
    var isRecording = false

    /// Records of offline tile downloads for this hike, enough to recompute (and
    /// so measure and remove) exactly the tiles each one saved.
    var offlineDownloads: [OfflineDownloadRecord]

    /// Cache keys of tiles auto-saved for this hike while browsing (OSM-style,
    /// non-bulk-downloadable providers) — recorded exactly, since (unlike
    /// ``OfflineDownloadRecord``) organic partial coverage can't be recomputed
    /// deterministically from a bounding box.
    ///
    /// The inline `= []`/`= false` defaults below (not just the `init`
    /// parameter defaults) are required so SwiftData's lightweight migration
    /// can backfill these values on existing rows — without them, adding the
    /// column fails with "missing attribute values on mandatory destination
    /// attribute" for anyone who already has hikes saved.
    var autoSavedTileKeys: [String] = []
    /// Whether auto-save is turned on for this hike's map.
    var autoSaveTilesEnabled = true
    /// Whether the elevation graph auto-scrolls to track the user's live
    /// location while browsing this hike.
    var autoFollowEnabled = true

    // Optional metadata pulled from the GPX file.
    var trackDescription: String?
    var author: String?
    var keywords: String?

    /// Metres of this route attributed to each ``TrailSurface``, keyed by the
    /// surface's raw value.
    ///
    /// Persisted rather than derived on demand because producing it needs the
    /// OSM trail graph for every region the route crosses, which for an
    /// imported hike means going to Overpass. Storing the answer keeps
    /// re-opening a hike free, and keeps casual browsing from turning into
    /// repeated requests against a volunteer-run API.
    ///
    /// Empty means "never analyzed", which is what the detail view offers a
    /// button for. The inline `= [:]` default is required for SwiftData
    /// lightweight migration, as for the auto-save fields above.
    var surfaceMetersByCategory: [String: Double] = [:]

    init(
        title: String,
        distanceMeters: Double,
        id: UUID = UUID(),
        date: Date = .now,
        tintHex: String = "#34C759",
        routeWidth: Double = 3,
        routeLinePatternID: String = RouteLinePattern.default.rawValue,
        symbol: String = "figure.hiking",
        route: [RouteCoordinate] = [],
        rawRoute: [RouteCoordinate] = [],
        isRecording: Bool = false,
        offlineDownloads: [OfflineDownloadRecord] = [],
        autoSavedTileKeys: [String] = [],
        autoSaveTilesEnabled: Bool = true,
        autoFollowEnabled: Bool = true,
        trackDescription: String? = nil,
        author: String? = nil,
        keywords: String? = nil,
        surfaceMetersByCategory: [String: Double] = [:]
    ) {
        self.id = id
        self.title = title
        self.distanceMeters = distanceMeters
        self.date = date
        self.tintHex = tintHex
        self.routeWidth = routeWidth
        self.routeLinePatternID = routeLinePatternID
        self.symbol = symbol
        self.route = route
        self.rawRoute = rawRoute
        self.isRecording = isRecording
        self.offlineDownloads = offlineDownloads
        self.autoSavedTileKeys = autoSavedTileKeys
        self.autoSaveTilesEnabled = autoSaveTilesEnabled
        self.autoFollowEnabled = autoFollowEnabled
        self.trackDescription = trackDescription
        self.author = author
        self.keywords = keywords
        self.surfaceMetersByCategory = surfaceMetersByCategory
    }
}

extension Hike {
    /// The persisted flag covers normal recording and recovery. The recorder's
    /// current ID bridges the short window after the finished route is saved
    /// but before shared-state and journal cleanup release ownership.
    func belongsToActiveRecording(currentHikeID: UUID?) -> Bool {
        isRecording || id == currentHikeID
    }
}

extension Hike {
    /// Adds complete or partial bulk coverage without accumulating redundant
    /// records for repeated attempts at the same provider/scale/depth.
    func mergeOfflineDownload(_ record: OfflineDownloadRecord) {
        let matches: (OfflineDownloadRecord) -> Bool = { existing in
            existing.providerID == record.providerID
                && existing.scale == record.scale
                && existing.maxZoom == record.maxZoom
        }

        if record.savedTileKeys.isEmpty {
            offlineDownloads.removeAll(where: matches)
            offlineDownloads.append(record)
            return
        }

        if offlineDownloads.contains(where: { matches($0) && $0.savedTileKeys.isEmpty }) { return }

        var mergedKeys = Set(record.savedTileKeys)
        offlineDownloads.removeAll { existing in
            guard matches(existing), !existing.savedTileKeys.isEmpty else { return false }
            mergedKeys.formUnion(existing.savedTileKeys)
            return true
        }
        guard !mergedKeys.isEmpty else { return }
        offlineDownloads.append(
            OfflineDownloadRecord(
                providerID: record.providerID,
                scale: record.scale,
                maxZoom: record.maxZoom,
                savedTileKeys: mergedKeys.sorted()
            )
        )
    }
}
