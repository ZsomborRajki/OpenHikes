//
//  CloudSyncSchema.swift
//  OpenHikes
//
//  The names iCloud knows this app's data by.
//
//  Every string in here is a storage contract in exactly the way
//  ``SettingsKey``'s are, only worse: these are shared with *other devices*
//  and with a server-side schema that CloudKit creates on first write and
//  never migrates. Renaming a field here doesn't rename it in the container —
//  it starts writing a second one, leaves the first behind on every record
//  already up there, and makes an older build and a newer build stop seeing
//  each other's hikes. Add fields; don't rename them.
//

import CloudKit
import Foundation

nonisolated enum CloudSyncSchema {
    /// The default container for this bundle identifier, spelled out rather
    /// than left to `CKContainer.default()` so that it is greppable and so
    /// that it matches the entitlement literally.
    static let containerIdentifier = "iCloud.tappium.com.OpenHikes"

    /// One custom zone for everything.
    ///
    /// Custom rather than the default zone because only a custom zone supports
    /// the change tokens ``CKSyncEngine`` fetches by — the default zone can't
    /// be synced incrementally, which would turn every launch into a full
    /// re-download of every route.
    static let zoneName = "Hikes"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    enum RecordType {
        static let hike = "Hike"
        static let photo = "HikePhoto"
    }

    /// Where a route stops being a record field and becomes a `CKAsset`.
    ///
    /// A record's non-asset fields have to fit in 1 MB all together, and a
    /// route is the only field with no upper bound — so the choice is between
    /// a limit this app can't honour and a branch. Compressed, this threshold
    /// is somewhere north of thirty thousand track points, which no ordinary
    /// walk reaches and an imported track occasionally does. Well under the
    /// megabyte so the rest of the record is never squeezed by it.
    private static let inlineRouteKilobyteLimit = 400
    static let inlineRouteByteLimit = inlineRouteKilobyteLimit * 1024

    enum HikeField {
        static let author = "author"
        static let autoFollowEnabled = "autoFollowEnabled"
        static let customName = "customName"
        static let date = "date"
        static let difficultyBreakdown = "difficultyBreakdown"
        static let distanceMeters = "distanceMeters"
        static let keywords = "keywords"
        static let rawRouteAsset = "rawRouteAsset"
        static let rawRouteData = "rawRouteData"
        static let routeAsset = "routeAsset"
        static let routeData = "routeData"
        static let routeLinePatternID = "routeLinePatternID"
        static let routeVersion = "routeVersion"
        static let routeWidth = "routeWidth"
        static let surfaceBreakdown = "surfaceBreakdown"
        static let symbol = "symbol"
        static let tintHex = "tintHex"
        static let title = "title"
        static let trackDescription = "trackDescription"
    }

    enum PhotoField {
        static let capturedAt = "capturedAt"
        /// A `CKRecord.Reference` with `.deleteSelf`, so a hike deleted on one
        /// device takes its pictures with it server-side — including the ones
        /// this device never saw and so could not have queued a delete for.
        static let hike = "hike"
        static let hikeID = "hikeID"
        static let image = "image"
        static let latitude = "latitude"
        static let longitude = "longitude"
        static let pathExtension = "pathExtension"
    }

    static func hikeRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    static func photoRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }
}
