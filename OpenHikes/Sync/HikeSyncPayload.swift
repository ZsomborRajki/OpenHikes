//
//  HikeSyncPayload.swift
//  OpenHikes
//
//  A hike with the device-local parts taken off it: the whole of what leaves
//  this device, and the whole of what a change arriving from another one is
//  allowed to write back.
//
//  This type exists so that "what syncs" is a list somebody can read rather
//  than a consequence of which framework was pointed at the model. SwiftData's
//  own CloudKit mirroring would have been four lines and would have carried
//  the entire row — including ``Hike/autoSavedTileKeys`` and
//  ``Hike/offlineDownloads``, which describe files in *this* device's
//  Application Support and mean nothing anywhere else. A second device
//  restoring them would believe it held an offline map it has never
//  downloaded: the storage screen would bill the user for bytes that aren't
//  there, and deleting them would free nothing. Tiles are re-fetchable by
//  definition; a walk is not. So the walk syncs and the tiles stay home.
//
//  Nothing here touches CloudKit. Turning one of these into a `CKRecord` is
//  ``HikeCloudRecord``'s job, which keeps the decision about *what* to sync
//  testable without an iCloud account.
//

import Foundation

/// The syncable shape of a ``Hike``.
///
/// Every stored property of `Hike` is either represented here or deliberately
/// absent — see ``HikeSyncPayload/init(hike:)`` for the absences and why.
/// `Codable` so a payload whose write to SwiftData failed can be held on disk
/// and retried — see ``CloudSyncStateStore/deferHikes(_:)``. A fetched change
/// is offered once and once only, so a log line is not a recovery.
nonisolated struct HikeSyncPayload: Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var customName: String?
    var distanceMeters: Double
    var date: Date
    var tintHex: String
    var routeWidth: Double
    var routeLinePatternID: String
    var symbol: String
    var trackDescription: String?
    var author: String?
    var keywords: String?
    /// Synced because it is a property of the *hike* — whether this trail is
    /// one you want the elevation graph to follow you along — rather than a
    /// property of the device you happened to set it on.
    var autoFollowEnabled: Bool
    var surfaceMetersByCategory: [String: Double]
    var difficultyMetersByGrade: [String: Double]
    var route: [RouteCoordinate]
    var rawRoute: [RouteCoordinate]
}

@MainActor
extension HikeSyncPayload {
    /// Snapshots a hike for upload, or answers `nil` for one that has no
    /// business leaving the device.
    ///
    /// Two hikes are refused. A draft (``Hike/isRecording``) is a row the
    /// recorder owns and rewrites on every fix; uploading it would spend a
    /// walk's worth of radio describing a route that isn't finished, and a
    /// second device would show a hike with no line on the map. A hike
    /// detached from its store has already been deleted, and reading it would
    /// only send back what is on its way out.
    ///
    /// Deliberately not read: ``Hike/autoSavedTileKeys``,
    /// ``Hike/offlineDownloads`` and ``Hike/autoSaveTilesEnabled`` — see this
    /// file's notes — and ``Hike/photos``, which travel as their own records
    /// so that adding one picture doesn't re-upload the other twenty.
    init?(hike: Hike) {
        guard hike.isAttached, !hike.isRecording else { return nil }
        self.init(
            id: hike.id,
            title: hike.title,
            customName: hike.customName,
            distanceMeters: hike.distanceMeters,
            date: hike.date,
            tintHex: hike.tintHex,
            routeWidth: hike.routeWidth,
            routeLinePatternID: hike.routeLinePatternID,
            symbol: hike.symbol,
            trackDescription: hike.trackDescription,
            author: hike.author,
            keywords: hike.keywords,
            autoFollowEnabled: hike.autoFollowEnabled,
            surfaceMetersByCategory: hike.surfaceMetersByCategory,
            difficultyMetersByGrade: hike.difficultyMetersByGrade,
            route: hike.route,
            rawRoute: hike.rawRoute
        )
    }

    /// Writes this payload over an existing hike.
    ///
    /// The mirror image of ``init(hike:)``: the same fields, and only those.
    /// The properties left alone are left alone on purpose — a hike arriving
    /// from another device must not be able to tell this one that it holds
    /// tiles it has never downloaded, nor to reopen a draft the recorder has
    /// finished with.
    ///
    /// `id` is not written either. It is the identity the record was looked up
    /// by, so writing it could only ever change it to itself — or, if the
    /// lookup were ever wrong, quietly graft one hike's identity onto another.
    func apply(to hike: Hike) {
        hike.title = title
        hike.customName = customName
        hike.distanceMeters = distanceMeters
        hike.date = date
        hike.tintHex = tintHex
        hike.routeWidth = routeWidth
        hike.routeLinePatternID = routeLinePatternID
        hike.symbol = symbol
        hike.trackDescription = trackDescription
        hike.author = author
        hike.keywords = keywords
        hike.autoFollowEnabled = autoFollowEnabled
        hike.surfaceMetersByCategory = surfaceMetersByCategory
        hike.difficultyMetersByGrade = difficultyMetersByGrade
        hike.route = route
        hike.rawRoute = rawRoute
    }

    /// A new hike carrying this payload, for a record that names one this
    /// device has never seen.
    ///
    /// Built through the memberwise initialiser and then overwritten by
    /// ``apply(to:)`` rather than by passing sixteen arguments twice: one
    /// place decides what a payload writes, so a field added to this type
    /// cannot be added to the update path and forgotten on the insert path.
    func makeHike() -> Hike {
        let hike = Hike(title: title, distanceMeters: distanceMeters, id: id, date: date)
        apply(to: hike)
        return hike
    }
}

/// One photo's metadata as it travels, plus the hike it belongs to.
///
/// The pixels are not in here. They are a `CKAsset` alongside this, for the
/// same reason they are a file rather than a SwiftData column: a photo is
/// megabytes, and everything that isn't the photo is bytes.
nonisolated struct HikePhotoSyncPayload: Codable, Equatable, Sendable {
    var hikeID: UUID
    var photo: HikePhoto

    init(hikeID: UUID, photo: HikePhoto) {
        self.hikeID = hikeID
        self.photo = photo
    }

    var id: UUID { photo.id }
}

@MainActor
extension HikePhotoSyncPayload {
    /// Every photo of a hike that is itself worth syncing, in a stable order.
    ///
    /// Ordered so that two devices that fell out of step re-upload in the same
    /// sequence, which makes a partly-completed sync resumable rather than
    /// arbitrary.
    static func payloads(of hike: Hike) -> [Self] {
        guard hike.isAttached, !hike.isRecording else { return [] }
        return hike.orderedPhotos.map { photo in
            Self(hikeID: hike.id, photo: photo)
        }
    }
}
