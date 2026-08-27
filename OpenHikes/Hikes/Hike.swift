//
//  Hike.swift
//  OpenHikes
//
//  A recorded or imported hike, persisted with SwiftData and backing the Hikes list.
//

import Foundation
import SwiftData

@Model
final class Hike {
    /// Backs the three shapes of query this model actually receives, so none
    /// of them is a table scan:
    ///
    /// - `\.id` — the identity lookup. `OpenHikesView.restoreLastSelectedHike()`,
    ///   `BackgroundTrailTracker` and `HikeRecorder.existingHike(sessionID:)`
    ///   all fetch a single row by it.
    /// - `\.date` — the hikes list, which is `@Query(sort: \Hike.date, order:
    ///   .reverse)` and is re-sorted on every insert.
    /// - `\.isRecording` — `deleteOrphanedRecordingHikes()`, which runs at
    ///   launch and has to find the drafts among every hike ever saved.
    ///
    /// Separate single-column indexes rather than one compound: these are
    /// three unrelated questions, and a compound index only serves a prefix of
    /// its own columns.
    ///
    /// Deliberately no `#Unique<Hike>([\.id])`, though the column is one. A
    /// uniqueness constraint turns inserting an existing id into a silent
    /// upsert, which would convert a duplicate-id bug from two visible rows
    /// into one row and lost data — and it is the kind of constraint that can
    /// refuse to open a store that already violates it, which for this app
    /// means the user reinstalls and loses every saved hike. The code already
    /// treats the id as unique by looking a hike up before creating one.
    /// CloudKit mirroring forbids one outright, so this is now settled rather
    /// than merely chosen.
    #Index<Hike>([\.id], [\.date], [\.isRecording])

    // Every non-optional column below carries an inline default, and now has
    // to: CloudKit mirroring refuses to open a store whose mandatory
    // attributes cannot be backfilled, and says so by failing to launch. The
    // values are placeholders for a row that is always fully initialised by
    // ``init(title:distanceMeters:)`` — nothing reads them.

    /// Stable identity, also used to key the route drawn on the map.
    var id = UUID()
    var title: String = ""
    /// Total route length, in meters.
    var distanceMeters: Double = 0
    /// Activity date — the GPX start time when available, otherwise the import date.
    var date = Date.distantPast
    /// Route tint, stored as "#RRGGBB" or "#RRGGBBAA". The alpha is used only for
    /// the map polyline; other UI reads ``tintOpaque``.
    var tintHex: String = "#34C759"
    /// Map polyline width, in points.
    var routeWidth: Double = 3
    /// How the map draws this route's line — see ``RouteLinePattern``. Stored
    /// as its stable string id (like ``tintHex``) rather than as an enum, so an
    /// unrecognised value degrades to the default instead of failing to decode.
    ///
    /// The inline default is required for SwiftData lightweight migration: a
    /// store written before this column existed has to backfill it.
    var routeLinePatternID: String = RouteLinePattern.default.rawValue
    /// SF Symbol shown in the row's colored circle.
    var symbol: String = "figure.hiking"
    /// Ordered track points making up the route.
    ///
    /// Stored externally so mirroring carries it as a `CKAsset` rather than as
    /// a record field: a day's recording is some twenty thousand points, which
    /// is a couple of megabytes encoded, and a `CKRecord`'s fields have to add
    /// up to less than one. Without this the longest hikes — the ones most
    /// worth keeping — are exactly the ones that would silently fail to sync.
    @Attribute(.externalStorage)
    var route: [RouteCoordinate] = []
    /// A user-chosen name that overrides the GPS/import-derived ``title``.
    /// `nil` means no override is set and the original title is displayed.
    ///
    /// Optional, so SwiftData's lightweight migration can backfill existing
    /// stores with `nil` instead of failing on a mandatory attribute.
    var customName: String?

    /// The unmatched GPS trace when trail matching moved a recorded route.
    /// Imported hikes and recordings that stayed raw leave this empty.
    ///
    /// External for the same reason ``route`` is: it is the same size and
    /// travels the same way.
    @Attribute(.externalStorage)
    var rawRoute: [RouteCoordinate] = []
    /// True while this row is the durable draft owned by an active recording.
    /// The route stays empty until Stop finalizes the draft in place.
    ///
    /// Mirrored along with everything else, which means a walk in progress is
    /// uploaded fix by fix and a second device shows a hike whose line is
    /// still being drawn. That is the price of letting SwiftData own sync:
    /// there is no hook to hold a row back.
    var isRecording: Bool = false

    /// Whether the elevation graph auto-scrolls to track the user's live
    /// location while browsing this hike.
    var autoFollowEnabled: Bool = true

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
    /// Empty means "never analyzed", which is what opening the hike triggers —
    /// see ``HikeDetailView``'s `loadTrailBreakdowns()`. The inline `= [:]`
    /// default is required for SwiftData lightweight migration, as for the
    /// auto-save fields above.
    var surfaceMetersByCategory: [String: Double] = [:]

    /// Metres of this route attributed to each ``TrailDifficulty``, keyed by
    /// the grade's raw value.
    ///
    /// Persisted for the same reason as ``surfaceMetersByCategory``: producing
    /// it requires the OSM graph for every region the route crosses. Empty
    /// means "never analyzed". The inline default is required for SwiftData
    /// lightweight migration.
    var difficultyMetersByGrade: [String: Double] = [:]

    /// Photos taken or imported while this hike was open, newest last once
    /// read through ``orderedPhotos``.
    ///
    /// Metadata only — a few dozen bytes each. The pixels live on disk under
    /// ``HikePhotoStore``, because a SwiftData column is loaded whole whenever
    /// the row is touched and a walk's worth of captures in one would be paid
    /// for by the hikes list.
    ///
    /// Which is also why a photo's pixels do not sync: mirroring carries this
    /// column and nothing else, so a second device receives the metadata and
    /// finds no file behind it. ``HikePhotoStore/hasImage(for:)`` is what the
    /// UI asks before it offers to show one.
    var photos: [HikePhoto] = []

    /// The resolved ``HikeLocalState``, remembered so repeated tile-ownership
    /// questions cost one fetch per hike rather than one per question.
    ///
    /// `@Transient` because it is a pointer into the *other* store: persisting
    /// it would be persisting a cross-store reference, which is the thing that
    /// cannot exist. Invalidated by ``Hike/deleteLocalState()`` and by the
    /// `isDeleted` check in ``Hike/localState``.
    @Transient var cachedLocalState: HikeLocalState?

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
        autoFollowEnabled: Bool = true,
        trackDescription: String? = nil,
        author: String? = nil,
        keywords: String? = nil,
        surfaceMetersByCategory: [String: Double] = [:],
        difficultyMetersByGrade: [String: Double] = [:],
        photos: [HikePhoto] = []
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
        self.autoFollowEnabled = autoFollowEnabled
        self.trackDescription = trackDescription
        self.author = author
        self.keywords = keywords
        self.surfaceMetersByCategory = surfaceMetersByCategory
        self.difficultyMetersByGrade = difficultyMetersByGrade
        self.photos = photos
    }
}

// MARK: - Device-local state

extension Hike {
    /// This hike's device-local storage record, or `nil` if it has never
    /// claimed a tile on this device.
    ///
    /// Resolved once and remembered, because the pre-filter in
    /// ``StoredTileDeletionPlan`` asks every hike in the library whether it has
    /// stored tiles and a fetch each would put the whole library's worth on the
    /// main actor during a delete — the same cost ``hasStoredTiles`` was
    /// written to avoid in the first place.
    var localState: HikeLocalState? {
        if let cachedLocalState, !cachedLocalState.isDeleted { return cachedLocalState }
        guard let modelContext else { return nil }
        let found = HikeLocalState.existing(for: id, in: modelContext)
        cachedLocalState = found
        return found
    }

    /// The same record, brought into existence by the first write.
    ///
    /// `nil` for a hike with no context — a value built but never inserted, or
    /// one already deleted — which makes the passthrough setters below no-ops
    /// there rather than silently inserting a sidecar into nothing.
    private var mutableLocalState: HikeLocalState? {
        if let localState { return localState }
        guard let modelContext, isAttached else { return nil }
        let created = HikeLocalState.forHike(id, in: modelContext)
        cachedLocalState = created
        return created
    }

    /// Records of offline tile downloads for this hike, enough to recompute
    /// (and so measure and remove) exactly the tiles each one saved.
    ///
    /// Reads through to ``HikeLocalState``, which lives in the unmirrored
    /// store — see that type for why this cannot be a column on `Hike` any
    /// more. Kept as a property rather than made an explicit lookup so the
    /// twenty call sites that only ever wanted a list of tile keys did not all
    /// have to learn about a second store.
    var offlineDownloads: [OfflineDownloadRecord] {
        get { localState?.offlineDownloads ?? [] }
        set { mutableLocalState?.offlineDownloads = newValue }
    }

    /// Cache keys of tiles auto-saved for this hike while browsing.
    var autoSavedTileKeys: [String] {
        get { localState?.autoSavedTileKeys ?? [] }
        set { mutableLocalState?.autoSavedTileKeys = newValue }
    }

    /// Whether auto-save is turned on for this hike's map. On by default,
    /// which is what a hike with no local record yet reports.
    var autoSaveTilesEnabled: Bool {
        get { localState?.autoSaveTilesEnabled ?? true }
        set { mutableLocalState?.autoSaveTilesEnabled = newValue }
    }

    /// Removes the sidecar, for a hike on its way out of the store.
    ///
    /// Explicit because the two rows are in different stores and so cannot be
    /// related: nothing cascades, and a sidecar left behind would go on
    /// claiming this hike's tiles forever, which is precisely the leak
    /// ``TileCache/trimCache(claimedBy:)`` cannot see.
    func deleteLocalState() {
        guard let modelContext, let state = localState else { return }
        cachedLocalState = nil
        modelContext.delete(state)
    }
}

extension Hike {
    /// Whether this hike is still part of a store, and so still worth writing
    /// to.
    ///
    /// Both halves are needed, because SwiftData answers differently at the
    /// two stages of a delete: `isDeleted` is true between `delete(_:)` and
    /// the save, and then goes *back* to false once the save detaches the
    /// object — at which point `modelContext` is what is nil. A check that
    /// asked only the first question would let a write through to a detached
    /// model, which is the quiet failure: it succeeds, and nothing persists
    /// it. `HikeAttachmentTests` pins the behaviour this reads.
    var isAttached: Bool { !isDeleted && modelContext != nil }

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
