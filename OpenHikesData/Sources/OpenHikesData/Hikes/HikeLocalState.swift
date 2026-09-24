//
//  HikeLocalState.swift
//  OpenHikes
//
//  The half of a hike that describes *this device's* disk, kept in its own
//  unmirrored store so CloudKit never sees it.
//
//  Everything here names files in this device's Application Support. Once the
//  app moved to SwiftData's own CloudKit mirroring, leaving these columns on
//  ``Hike`` stopped being a cosmetic problem and became a data-losing one:
//  mirroring syncs a whole row and resolves conflicts last-writer-wins, so a
//  second device's tile inventory would overwrite this one's. ``TileOwnership``
//  derives the tile claim set from exactly these two arrays, and
//  `TileCache.trimCache(claimedBy:)` deletes whatever no hike claims — so the
//  overwrite would strip this device of offline maps it really had downloaded,
//  at the next launch, with no way to notice.
//
//  A separate `@Model` in a second ``ModelConfiguration`` rather than a
//  relationship, because Core Data — and so SwiftData — forbids a relationship
//  that crosses two stores. The link is the hike's `id`, and ``Hike``'s
//  computed passthroughs are what keep that fact from leaking into the twenty
//  call sites that only ever wanted `hike.autoSavedTileKeys`.
//

import Foundation
import SwiftData

@Model
public final class HikeLocalState {
    /// The hike this belongs to, and the only way back to it: a cross-store
    /// relationship is not available, so the join is done by value.
    ///
    /// Indexed because every access goes through it — see
    /// ``Hike/localState`` — and a table scan per tile-ownership question
    /// would land on the main actor.
    #Index<HikeLocalState>([\.hikeID])

    public var hikeID: UUID

    /// Records of offline tile downloads for this hike, enough to recompute
    /// (and so measure and remove) exactly the tiles each one saved.
    public var offlineDownloads: [OfflineDownloadRecord] = []

    /// Cache keys of tiles auto-saved for this hike while browsing (OSM-style,
    /// non-bulk-downloadable providers) — recorded exactly, since (unlike
    /// ``OfflineDownloadRecord``) organic partial coverage can't be recomputed
    /// deterministically from a bounding box.
    public var autoSavedTileKeys: [String] = []

    /// Whether auto-save is turned on for this hike's map.
    ///
    /// Device-local rather than a synced preference because it is a statement
    /// about whether *this* phone should be spending its storage and its
    /// connection on a map, which is not something the other one gets a vote
    /// on.
    public var autoSaveTilesEnabled: Bool = true

    /// The walk under way along this hike, between the milestones that write
    /// it — see ``TrailWalkRecord``.
    ///
    /// Device-local on purpose, and the reason it is a column here rather
    /// than a row in the mirrored store: a walk in progress is this phone's
    /// walk, and last-writer-wins between two devices would be exactly the
    /// tile-inventory bug this store exists to prevent. `nil` is the ordinary
    /// state, so the row costs nothing for a hike nobody is walking.
    public var walkInProgress: TrailWalkRecord?

    /// Positive evidence that this device created or recovered the recording
    /// journal for this hike. Only the recorder sets it; browsing a synced
    /// draft's map or adding a photo must never confer ownership.
    ///
    /// False also means unknown: a draft has no ownership evidence until
    /// a matching local journal is recovered. Retained after saving, but only
    /// consulted for `isRecording` rows by the abandoned-draft sweep.
    public var ownsRecordingDraft: Bool = false

    /// The `HKWorkout` this hike was written to in *this* device's Health
    /// store, or `nil` if it never was.
    ///
    /// Here rather than on ``Hike`` for exactly the reason every other column
    /// in this file is: it identifies a record in a store that does not leave
    /// this device. Mirroring it would point a second phone at a workout it
    /// does not have, and — unlike the tile arrays — there would be no sweep
    /// that could notice, because a Health store nobody can read cannot be
    /// reconciled against.
    ///
    /// Written after the workout exists, so a row carrying one is a row whose
    /// export is known to have landed.
    ///
    /// Read by ``HikeDeletion``, which is what it was stored for: an
    /// identifier thrown away cannot be recovered, and Health is a second
    /// store that must never hold a walk this app does not — see
    /// ``HikeWorkoutWriting/write(_:)``. It is read while the sidecar is still
    /// here and spent after the deletion commits, for the reason the photo
    /// files are; that ordering is argued in `HikeDeletion.swift`.
    public var healthWorkoutID: UUID?

    /// The watch recording this hike was imported from, or `nil` for a hike
    /// that came from anywhere else.
    ///
    /// This is what makes the import idempotent, and it is why the column
    /// exists at all: `transferUserInfo` guarantees delivery and guarantees
    /// nothing about *how many times* — a receipt lost on the way back leaves
    /// the watch holding a walk it will offer again on the next connection.
    /// Recognising the second arrival is the difference between that being
    /// free and it being a duplicate hike a hiker has to find and delete.
    ///
    /// Here rather than on ``Hike`` for the reason ``healthWorkoutID`` is: it
    /// names something outside the synced store — a session on a watch paired
    /// with *this* phone, which is the only device that will ever receive that
    /// transfer. A second phone mirroring the column would learn an identifier
    /// it can do nothing with, and, unlike the tile arrays, there is no sweep
    /// that could notice.
    ///
    /// See `WatchWalkImport`, which is the only writer and the only reader.
    public var watchSessionID: UUID?

    /// This hike's place in a hand-ordered list, or `nil` while the list is
    /// still in date order.
    ///
    /// Device-local because a hand-ordered library is a statement about *this*
    /// phone's list. The position is also the one thing here that a second
    /// device could disagree about harmlessly — two phones with different
    /// orders are two hikers' worth of preference, not a conflict — and
    /// mirroring it would buy an ordering fight on every sync for something
    /// neither device can be wrong about.
    ///
    /// Set for **every** hike at once, by the first drag, or for none of them:
    /// a list that is half hand-ordered has no answer for where the rest go.
    /// See ``HikeListOrder``, which owns both halves of that.
    public var listOrder: Int?

    /// This hike's total climb and descent in metres, worked out once and kept.
    ///
    /// `nil` until something has needed them. They are not on ``Hike`` because
    /// they are not facts a second device would disagree about — they are a
    /// *cache* of what the route already says, and a cache belongs on the
    /// device that paid for it. Recomputing them on another phone costs one
    /// pass over a route it already has.
    ///
    /// Cached at all because the alternative is worse than it looks:
    /// ``Hike/routeStatistics`` walks every point of every route, and sorting
    /// a library by climb would do that for every hike on every redraw. See
    /// ``HikeListMetrics``, which fills these off the main actor.
    public var climbMeters: Double?
    public var descentMeters: Double?

    public init(hikeID: UUID) {
        self.hikeID = hikeID
    }
}

// MARK: - Lookup

public extension HikeLocalState {
    /// The row for `hikeID`, or `nil` when this device has no local state
    /// for it.
    ///
    /// Deliberately does not create one. A read is a read: materialising a row
    /// because something asked whether a hike had offline maps would turn the
    /// hikes list into a writer, and a library of three hundred hikes into
    /// three hundred inserts on the first delete.
    static func existing(for hikeID: UUID, in context: ModelContext) -> HikeLocalState? {
        // `try?` because every caller of *this* spelling is a property
        // accessor with a meaningful empty answer — no stored tiles — and the
        // alternative is making `hike.autoSavedTileKeys` throwing at twenty
        // call sites to report a failure none of them could act on.
        try? fetchExisting(for: hikeID, in: context)
    }

    /// The same row, with a fetch that *failed* reported rather than answered.
    ///
    /// The two answers above are not interchangeable everywhere. A screen
    /// asking what a hike has downloaded can read "no row" as "no tiles" and
    /// be no worse than out of date; anything building a tile *claim set*
    /// cannot, because a hike missing from that set is not a hike that claims
    /// nothing — it is a hike whose tiles are about to be deleted while it
    /// goes on listing them. ``Hike/tileClaim()`` is the caller that needs the
    /// distinction, and it needs it in the type.
    static func fetchExisting(for hikeID: UUID, in context: ModelContext) throws -> HikeLocalState? {
        var descriptor = FetchDescriptor<HikeLocalState>(
            predicate: #Predicate { $0.hikeID == hikeID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The row for `hikeID`, created and inserted by the first local write.
    static func forHike(_ hikeID: UUID, in context: ModelContext) -> HikeLocalState {
        if let existing = existing(for: hikeID, in: context) { return existing }
        let created = HikeLocalState(hikeID: hikeID)
        context.insert(created)
        return created
    }
}
