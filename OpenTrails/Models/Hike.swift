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
    /// SF Symbol shown in the row's colored circle.
    var symbol: String
    /// Ordered track points making up the route.
    var route: [RouteCoordinate]

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

    init(
        id: UUID = UUID(),
        title: String,
        distanceMeters: Double,
        date: Date = .now,
        tintHex: String = "#34C759",
        routeWidth: Double = 3,
        symbol: String = "figure.hiking",
        route: [RouteCoordinate] = [],
        offlineDownloads: [OfflineDownloadRecord] = [],
        autoSavedTileKeys: [String] = [],
        autoSaveTilesEnabled: Bool = true,
        autoFollowEnabled: Bool = true,
        trackDescription: String? = nil,
        author: String? = nil,
        keywords: String? = nil
    ) {
        self.id = id
        self.title = title
        self.distanceMeters = distanceMeters
        self.date = date
        self.tintHex = tintHex
        self.routeWidth = routeWidth
        self.symbol = symbol
        self.route = route
        self.offlineDownloads = offlineDownloads
        self.autoSavedTileKeys = autoSavedTileKeys
        self.autoSaveTilesEnabled = autoSaveTilesEnabled
        self.autoFollowEnabled = autoFollowEnabled
        self.trackDescription = trackDescription
        self.author = author
        self.keywords = keywords
    }
}
