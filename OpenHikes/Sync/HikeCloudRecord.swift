//
//  HikeCloudRecord.swift
//  OpenHikes
//
//  Turning a ``HikeSyncPayload`` into a `CKRecord` and back.
//
//  Everything here is `nonisolated` and does no I/O beyond writing an asset's
//  staging file, because it runs off the main thread by contract: encoding a
//  twenty-thousand-point route means compressing a couple of megabytes, which
//  is the same argument ``HikePhotoStore`` and the tile pipeline make.
//
//  Records are *mutated in place* rather than built fresh. A `CKRecord`
//  carries a change tag, and a save built from a blank record is a save that
//  claims to know nothing about what the server already holds — which is how
//  a conflict turns from "merge" into "clobber". The caller hands in either
//  the last record the server acknowledged or a new one, and this fills it.
//

import CloudKit
import Foundation

nonisolated enum HikeCloudRecord {
    enum Failure: Error {
        case missingField(String)
        case routeUnreadable(RouteArchive.Failure)
        case stagingFailed
    }

    // MARK: - Encoding

    /// Writes `payload` into `record`, staging the route as an asset when it
    /// is too big to be a field.
    ///
    /// - Parameter staging: Where an oversized route's file is written. The
    ///   file has to outlive this call — CloudKit reads it when the batch is
    ///   actually sent, which is later and on another thread — so it is the
    ///   caller who owns it and the caller who cleans it up once the send is
    ///   acknowledged.
    /// - Parameter inlineLimit: The size above which a route becomes an asset.
    ///   A parameter only so that a test can cross the threshold with a route
    ///   of six points instead of thirty thousand.
    static func encode(
        _ payload: HikeSyncPayload,
        into record: CKRecord,
        staging: CloudAssetStaging,
        inlineLimit: Int = CloudSyncSchema.inlineRouteByteLimit
    ) throws(Failure) {
        record[CloudSyncSchema.HikeField.title] = payload.title
        record[CloudSyncSchema.HikeField.customName] = payload.customName
        record[CloudSyncSchema.HikeField.distanceMeters] = payload.distanceMeters
        record[CloudSyncSchema.HikeField.date] = payload.date
        record[CloudSyncSchema.HikeField.tintHex] = payload.tintHex
        record[CloudSyncSchema.HikeField.routeWidth] = payload.routeWidth
        record[CloudSyncSchema.HikeField.routeLinePatternID] = payload.routeLinePatternID
        record[CloudSyncSchema.HikeField.symbol] = payload.symbol
        record[CloudSyncSchema.HikeField.trackDescription] = payload.trackDescription
        record[CloudSyncSchema.HikeField.author] = payload.author
        record[CloudSyncSchema.HikeField.keywords] = payload.keywords
        record[CloudSyncSchema.HikeField.autoFollowEnabled] = payload.autoFollowEnabled
        record[CloudSyncSchema.HikeField.routeVersion] = RouteArchive.version
        record[CloudSyncSchema.HikeField.surfaceBreakdown] =
            BreakdownArchive.encode(payload.surfaceMetersByCategory)
        record[CloudSyncSchema.HikeField.difficultyBreakdown] =
            BreakdownArchive.encode(payload.difficultyMetersByGrade)

        try store(
            route: payload.route,
            in: record,
            dataField: CloudSyncSchema.HikeField.routeData,
            assetField: CloudSyncSchema.HikeField.routeAsset,
            staging: staging,
            inlineLimit: inlineLimit
        )
        try store(
            route: payload.rawRoute,
            in: record,
            dataField: CloudSyncSchema.HikeField.rawRouteData,
            assetField: CloudSyncSchema.HikeField.rawRouteAsset,
            staging: staging,
            inlineLimit: inlineLimit
        )
    }

    /// Both fields are always written — the used one to its value and the
    /// unused one to `nil` — so that a route that grew past the inline limit
    /// (or shrank back under it) doesn't leave a stale copy of itself in the
    /// other field for a reader to find first.
    private static func store(
        route: [RouteCoordinate],
        in record: CKRecord,
        dataField: String,
        assetField: String,
        staging: CloudAssetStaging,
        inlineLimit: Int
    ) throws(Failure) {
        let encoded: Data
        do {
            encoded = try RouteArchive.encode(route)
        } catch {
            throw .routeUnreadable(error)
        }

        guard encoded.count > inlineLimit else {
            record[dataField] = encoded
            record[assetField] = nil
            return
        }

        guard let url = staging.stage(
            encoded,
            named: "\(record.recordID.recordName)-\(assetField)"
        ) else { throw .stagingFailed }
        record[dataField] = nil
        record[assetField] = CKAsset(fileURL: url)
    }

    // MARK: - Decoding

    static func decode(_ record: CKRecord) throws(Failure) -> HikeSyncPayload {
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            throw .missingField("recordName")
        }
        let version = (record[CloudSyncSchema.HikeField.routeVersion] as? Int)
            ?? RouteArchive.version

        return HikeSyncPayload(
            id: id,
            title: try require(record, CloudSyncSchema.HikeField.title),
            customName: record[CloudSyncSchema.HikeField.customName] as? String,
            distanceMeters: try require(record, CloudSyncSchema.HikeField.distanceMeters),
            date: try require(record, CloudSyncSchema.HikeField.date),
            tintHex: try require(record, CloudSyncSchema.HikeField.tintHex),
            routeWidth: try require(record, CloudSyncSchema.HikeField.routeWidth),
            routeLinePatternID: try require(record, CloudSyncSchema.HikeField.routeLinePatternID),
            symbol: try require(record, CloudSyncSchema.HikeField.symbol),
            trackDescription: record[CloudSyncSchema.HikeField.trackDescription] as? String,
            author: record[CloudSyncSchema.HikeField.author] as? String,
            keywords: record[CloudSyncSchema.HikeField.keywords] as? String,
            autoFollowEnabled: record[CloudSyncSchema.HikeField.autoFollowEnabled] as? Bool ?? true,
            surfaceMetersByCategory: BreakdownArchive.decode(
                record[CloudSyncSchema.HikeField.surfaceBreakdown] as? Data
            ),
            difficultyMetersByGrade: BreakdownArchive.decode(
                record[CloudSyncSchema.HikeField.difficultyBreakdown] as? Data
            ),
            route: try route(
                in: record,
                dataField: CloudSyncSchema.HikeField.routeData,
                assetField: CloudSyncSchema.HikeField.routeAsset,
                version: version
            ),
            rawRoute: try route(
                in: record,
                dataField: CloudSyncSchema.HikeField.rawRouteData,
                assetField: CloudSyncSchema.HikeField.rawRouteAsset,
                version: version
            )
        )
    }

    /// An absent route decodes to an empty one rather than to a failure:
    /// ``Hike/rawRoute`` is legitimately empty for every imported hike, and a
    /// record written by a build that predates one of these fields is a hike
    /// worth showing without its raw trace rather than a hike worth dropping.
    private static func route(
        in record: CKRecord,
        dataField: String,
        assetField: String,
        version: Int
    ) throws(Failure) -> [RouteCoordinate] {
        let data: Data?
        if let inline = record[dataField] as? Data {
            data = inline
        } else if let asset = record[assetField] as? CKAsset, let url = asset.fileURL {
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            data = nil
        }

        guard let data, !data.isEmpty else { return [] }
        do {
            return try RouteArchive.decode(data, version: version)
        } catch {
            throw .routeUnreadable(error)
        }
    }

    private static func require<Value>(
        _ record: CKRecord,
        _ field: String
    ) throws(Failure) -> Value {
        guard let value = record[field] as? Value else {
            throw .missingField(field)
        }
        return value
    }
}

// MARK: - Photos

nonisolated enum HikePhotoCloudRecord {
    /// Writes a photo's metadata, and points the record's asset at the file
    /// the app already keeps.
    ///
    /// Deliberately not staged into a copy: a hike's pictures are the largest
    /// thing this app stores, and duplicating each one so that CloudKit can
    /// read it would briefly double the biggest number on the storage screen.
    /// `CKAsset` only reads the file it is given.
    static func encode(
        _ payload: HikePhotoSyncPayload,
        into record: CKRecord,
        imageURL: URL
    ) {
        record[CloudSyncSchema.PhotoField.hikeID] = payload.hikeID.uuidString
        record[CloudSyncSchema.PhotoField.capturedAt] = payload.photo.capturedAt
        record[CloudSyncSchema.PhotoField.pathExtension] = payload.photo.pathExtension
        record[CloudSyncSchema.PhotoField.latitude] = payload.photo.latitude
        record[CloudSyncSchema.PhotoField.longitude] = payload.photo.longitude
        record[CloudSyncSchema.PhotoField.image] = CKAsset(fileURL: imageURL)
        record[CloudSyncSchema.PhotoField.hike] = CKRecord.Reference(
            recordID: CloudSyncSchema.hikeRecordID(payload.hikeID),
            action: .deleteSelf
        )
    }

    /// The metadata half of a fetched photo. The pixels are read separately —
    /// see ``imageURL(in:)`` — because CloudKit's staged asset file is deleted
    /// out from under the app shortly after the delegate returns, so it has to
    /// be copied *now* while this only has to be applied to SwiftData later.
    static func decode(_ record: CKRecord) -> HikePhotoSyncPayload? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let hikeString = record[CloudSyncSchema.PhotoField.hikeID] as? String,
              let hikeID = UUID(uuidString: hikeString),
              let capturedAt = record[CloudSyncSchema.PhotoField.capturedAt] as? Date,
              let pathExtension = record[CloudSyncSchema.PhotoField.pathExtension] as? String
        else { return nil }

        var photo = HikePhoto(
            id: id,
            capturedAt: capturedAt,
            pathExtension: pathExtension
        )
        photo.latitude = record[CloudSyncSchema.PhotoField.latitude] as? Double
        photo.longitude = record[CloudSyncSchema.PhotoField.longitude] as? Double
        return HikePhotoSyncPayload(hikeID: hikeID, photo: photo)
    }

    static func imageURL(in record: CKRecord) -> URL? {
        (record[CloudSyncSchema.PhotoField.image] as? CKAsset)?.fileURL
    }
}

// MARK: - Breakdowns

/// The surface and difficulty tallies, as one field each rather than as a
/// CloudKit dictionary — which does not exist. JSON because these are a
/// handful of keys and a handful of doubles, so the compression that
/// ``RouteArchive`` needs would cost more than it saved.
nonisolated enum BreakdownArchive {
    static func encode(_ breakdown: [String: Double]) -> Data? {
        guard !breakdown.isEmpty else { return nil }
        return try? JSONEncoder().encode(breakdown)
    }

    /// An unreadable breakdown decodes to empty, which is the value that means
    /// "never analyzed" — so the receiving device simply re-derives it from the
    /// trail graph the next time the hike is opened.
    static func decode(_ data: Data?) -> [String: Double] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }
}
