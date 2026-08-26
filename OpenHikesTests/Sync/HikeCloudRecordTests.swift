//
//  HikeCloudRecordTests.swift
//  OpenHikesTests
//
//  The CKRecord mapping, tested without CloudKit: a `CKRecord` can be built,
//  filled and read back in process, which covers everything except the network
//  — and the network is the part `CKSyncEngine` owns.
//

import CloudKit
import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Hike cloud record")
struct HikeCloudRecordTests {
    private enum Constants {
        /// Small enough that six route points cross it, so the asset branch is
        /// reachable without building a thirty-thousand-point route.
        static let tinyInlineLimit = 8
        static let surface = ["gravel": 1200.0]
        static let difficulty = ["T2": 1200.0]
        static let latitude = 47.63
        static let longitude = 12.86
        static let imageBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
    }

    /// A staging directory of this suite's own. Suites run in parallel, and
    /// `Caches` belongs to the host app.
    private static func makeStaging() -> CloudAssetStaging {
        CloudAssetStaging(
            directory: URL.temporaryDirectory.appendingPathComponent(
                "HikeCloudRecordTests-\(UUID().uuidString)",
                isDirectory: true
            )
        )
    }

    private static func makePayload() throws -> HikeSyncPayload {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.surfaceMetersByCategory = Constants.surface
            hike.difficultyMetersByGrade = Constants.difficulty
            hike.rawRoute = Fixture.ridgeRoute
        }
        return try #require(HikeSyncPayload(hike: hike))
    }

    private static func makeHikeRecord(for payload: HikeSyncPayload) -> CKRecord {
        CKRecord(
            recordType: CloudSyncSchema.RecordType.hike,
            recordID: CloudSyncSchema.hikeRecordID(payload.id)
        )
    }

    @Test("A hike round-trips through a record")
    func hikeRoundTrips() throws {
        let staging = Self.makeStaging()
        defer { staging.removeAll() }
        let original = try Self.makePayload()
        let record = Self.makeHikeRecord(for: original)

        try HikeCloudRecord.encode(original, into: record, staging: staging)

        #expect(try HikeCloudRecord.decode(record) == original)
    }

    /// Both fields are always written, so a route that shrank back under the
    /// limit cannot leave a stale asset for a reader to find first.
    @Test("A small route travels inline and leaves no asset")
    func smallRouteIsInline() throws {
        let staging = Self.makeStaging()
        defer { staging.removeAll() }
        let payload = try Self.makePayload()
        let record = Self.makeHikeRecord(for: payload)

        try HikeCloudRecord.encode(payload, into: record, staging: staging)

        #expect(record[CloudSyncSchema.HikeField.routeData] is Data)
        #expect(record[CloudSyncSchema.HikeField.routeAsset] as? CKAsset == nil)
    }

    @Test("A route past the inline limit becomes an asset and still round-trips")
    func largeRouteBecomesAsset() throws {
        let staging = Self.makeStaging()
        defer { staging.removeAll() }
        let payload = try Self.makePayload()
        let record = Self.makeHikeRecord(for: payload)

        try HikeCloudRecord.encode(
            payload,
            into: record,
            staging: staging,
            inlineLimit: Constants.tinyInlineLimit
        )

        #expect(record[CloudSyncSchema.HikeField.routeData] as? Data == nil)
        #expect(record[CloudSyncSchema.HikeField.routeAsset] is CKAsset)
        #expect(try HikeCloudRecord.decode(record) == payload)
    }

    /// A record missing a field the app requires is a record from a build this
    /// one doesn't understand. Refused rather than half-decoded.
    @Test("A record missing a required field is refused")
    func missingFieldIsRefused() throws {
        let staging = Self.makeStaging()
        defer { staging.removeAll() }
        let payload = try Self.makePayload()
        let record = Self.makeHikeRecord(for: payload)
        try HikeCloudRecord.encode(payload, into: record, staging: staging)
        record[CloudSyncSchema.HikeField.title] = nil

        #expect(throws: HikeCloudRecord.Failure.self) {
            try HikeCloudRecord.decode(record)
        }
    }

    @Test("A photo round-trips through a record, carrying its hike")
    func photoRoundTrips() throws {
        let staging = Self.makeStaging()
        defer { staging.removeAll() }
        let hikeID = UUID()
        let photo = HikePhoto(
            id: UUID(),
            capturedAt: .now,
            pathExtension: "jpg",
            coordinate: CLLocationCoordinate2D(
                latitude: Constants.latitude,
                longitude: Constants.longitude
            )
        )
        let payload = HikePhotoSyncPayload(hikeID: hikeID, photo: photo)
        let imageURL = try #require(
            staging.stage(Data(Constants.imageBytes), named: "photo.jpg")
        )
        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.photo,
            recordID: CloudSyncSchema.photoRecordID(photo.id)
        )

        HikePhotoCloudRecord.encode(payload, into: record, imageURL: imageURL)

        #expect(HikePhotoCloudRecord.decode(record) == payload)
        #expect(HikePhotoCloudRecord.imageURL(in: record) != nil)
        // The cascade that removes a hike's pictures server-side, so a device
        // that never saw them still ends up without them.
        let reference = record[CloudSyncSchema.PhotoField.hike] as? CKRecord.Reference
        #expect(reference?.action == .deleteSelf)
        #expect(reference?.recordID == CloudSyncSchema.hikeRecordID(hikeID))
    }
}
