//
//  CloudKitTrailCellDatabaseTests.swift
//  OpenHikesTests
//
//  How what CloudKit hands back about the trail squares is read — above all,
//  which of its failures means *there is no such square*.
//
//  That one distinction decides what a hiker is told. A square that is not
//  there, in a set that covers the world, is *no trails here*; a square that
//  could not be read is a search that goes to Overpass instead. Reading a
//  timeout as the first would put the wrong sentence under the search button
//  on exactly the afternoons the network is bad.
//
//  Nothing here reaches CloudKit: the records and the errors are built in the
//  suite and handed to ``CloudKitTrailCellDatabase/answer(from:names:)``,
//  which is the half of the conformance that touches no network. See *A suite
//  must never reach the real transport* in the repository instructions.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Testing

@Suite("CloudKit trail cell database")
struct CloudKitTrailCellDatabaseTests {
    private static let square = "trails1_550_771"
    private static let neighbor = "trails1_550_772"

    private static func manifest(complete: Int?) -> CKRecord {
        let record = CKRecord(
            recordType: CommunitySchema.trailManifestType,
            recordID: CKRecord.ID(recordName: TrailCellGrid.manifestRecordName)
        )
        record[CommunitySchema.TrailManifest.complete] = complete
        return record
    }

    /// A square's record, with `bytes` as its asset — written to a file of
    /// the case's own first, because an asset is a file and nothing else.
    private static func cell(named name: String, bytes: Data?) throws -> CKRecord {
        let record = CKRecord(
            recordType: CommunitySchema.trailCellType,
            recordID: CKRecord.ID(recordName: name)
        )
        if let bytes {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("trail-cell-\(UUID().uuidString)")
            try bytes.write(to: url)
            record[CommunitySchema.TrailCell.routes] = CKAsset(fileURL: url)
        }
        return record
    }

    // MARK: - The manifest

    @Test("a manifest flagged complete says the squares are the whole world")
    func aCompleteManifest() {
        let answer = CloudKitTrailCellDatabase.answer(
            from: [TrailCellGrid.manifestRecordName: .success(Self.manifest(complete: 1))],
            names: []
        )

        #expect(answer.manifest == .complete)
    }

    @Test("a manifest that is not flagged complete says they are part of it", arguments: [0, 2, nil])
    func aPartialManifest(flag: Int?) {
        let answer = CloudKitTrailCellDatabase.answer(
            from: [TrailCellGrid.manifestRecordName: .success(Self.manifest(complete: flag))],
            names: []
        )

        #expect(answer.manifest == .partial)
    }

    @Test("no manifest record is no squares published, which is not a failure")
    func noManifest() {
        let answer = CloudKitTrailCellDatabase.answer(
            from: [TrailCellGrid.manifestRecordName: .failure(CKError(.unknownItem))],
            names: []
        )

        #expect(answer.manifest == .absent)
    }

    @Test("a manifest that could not be read is not a manifest that is missing")
    func anUnreadManifest() {
        let refused = CloudKitTrailCellDatabase.answer(
            from: [TrailCellGrid.manifestRecordName: .failure(CKError(.networkFailure))],
            names: []
        )
        let unanswered = CloudKitTrailCellDatabase.answer(from: [:], names: [])

        #expect(refused.manifest == .unread)
        #expect(unanswered.manifest == .unread)
    }

    // MARK: - The squares

    @Test("a square's record is read as the bytes of its asset")
    func aSquareIsFound() throws {
        let bytes = TrailCellFile(relations: []).encoded()

        let answer = CloudKitTrailCellDatabase.answer(
            from: [Self.square: .success(try Self.cell(named: Self.square, bytes: bytes))],
            names: [Self.square]
        )

        #expect(answer.cells == [Self.square: .found(bytes)])
    }

    @Test("only the server saying there is no such record is a square that is absent")
    func onlyUnknownItemIsAbsent() {
        let answer = CloudKitTrailCellDatabase.answer(
            from: [
                Self.square: .failure(CKError(.unknownItem)),
                Self.neighbor: .failure(CKError(.requestRateLimited)),
            ],
            names: [Self.square, Self.neighbor]
        )

        #expect(answer.cells == [Self.square: .absent, Self.neighbor: .failed])
    }

    @Test("a record with no file where its routes should be has failed, not answered")
    func aRecordWithoutItsAsset() throws {
        let answer = CloudKitTrailCellDatabase.answer(
            from: [Self.square: .success(try Self.cell(named: Self.square, bytes: nil))],
            names: [Self.square]
        )

        #expect(answer.cells == [Self.square: .failed])
    }

    @Test("a square the answer says nothing about has failed")
    func aSquareLeftOut() {
        let answer = CloudKitTrailCellDatabase.answer(from: [:], names: [Self.square])

        #expect(answer.cells == [Self.square: .failed])
    }

    /// The manifest rides along in the same request under its own name, and
    /// must not come back as though it were a square somebody asked about.
    @Test("the manifest is not one of the squares")
    func theManifestIsNotASquare() {
        let answer = CloudKitTrailCellDatabase.answer(
            from: [
                TrailCellGrid.manifestRecordName: .success(Self.manifest(complete: 1)),
                Self.square: .failure(CKError(.unknownItem)),
            ],
            names: [Self.square]
        )

        #expect(answer.cells.keys.sorted() == [Self.square])
    }
}
