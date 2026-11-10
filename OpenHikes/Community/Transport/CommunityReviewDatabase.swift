//
//  CommunityReviewDatabase.swift
//  OpenHikes
//
//  What a reviewer's look at the queue, and the two publications made from
//  it, ask the public database for — as a seam a suite can script.
//
//  What the queue gets right or wrong is spread over several requests rather
//  than held in any one of them: a page of notices, the submissions behind
//  them, which of those are already published, and the next page when one was
//  spent on notices that are not work. The case that made this seam is a
//  publication whose notice could not be cleared — the publication saved, the
//  delete after it refused — followed by the next look at the queue. A stub
//  standing in for the whole transport can answer that look any way it is
//  told to, which proves nothing about the transport. Under it, the real
//  queue read and the real publications run, the real records and queries are
//  built, and a script refuses exactly the request a suite wants refused,
//  without a container, an account or a network, and without a record ever
//  reaching the public database, which no suite may touch.
//
//  Narrow for the reason ``CommunityRecordWriting`` is narrow: the five calls
//  the reviewer's path makes, spelled as CloudKit spells them, and nothing a
//  suite would have to guess at. Only the queue read and the two publications
//  go through it. Declining, taking down and editing a submission's
//  photographs still reach the database directly, so a suite that calls one
//  of those calls the real public database.
//
//  The cursor is the one thing that is not CloudKit's own type, because a
//  `CKQueryOperation.Cursor` has no initializer a suite could call. In the app
//  it is CloudKit's.
//

import CloudKit
import Foundation

/// The reads, the save and the delete behind the reviewer's queue.
///
/// `@concurrent` on every requirement for the reason every requirement on
/// ``CommunityTransporting`` is.
nonisolated protocol CommunityReviewDatabase: Sendable {
    /// Where the next page of a query starts.
    associatedtype Cursor: Sendable

    /// One page of a query, and where the next one starts, when there is one.
    typealias Page = (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: Cursor?)

    @concurrent
    func records(matching query: CKQuery, resultsLimit: Int) async throws -> Page

    @concurrent
    func records(continuingMatchFrom cursor: Cursor, resultsLimit: Int) async throws -> Page

    @concurrent
    func records(
        for ids: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]

    @concurrent
    func save(_ record: CKRecord) async throws -> CKRecord

    @concurrent
    func deleteRecord(withID id: CKRecord.ID) async throws -> CKRecord.ID
}

/// The public database of the app's container, which is the only one the
/// shipping app reviews against.
nonisolated struct CloudKitReviewDatabase: CommunityReviewDatabase {
    typealias Cursor = CKQueryOperation.Cursor

    let containerIdentifier: String

    /// Built on every call and not held, for the reason
    /// `CloudKitCommunityTransport.swift`'s header gives.
    private var database: CKDatabase {
        CKContainer(identifier: containerIdentifier).publicCloudDatabase
    }

    @concurrent
    func records(matching query: CKQuery, resultsLimit: Int) async throws -> Page {
        try await database.records(matching: query, resultsLimit: resultsLimit)
    }

    @concurrent
    func records(
        continuingMatchFrom cursor: Cursor,
        resultsLimit: Int
    ) async throws -> Page {
        try await database.records(continuingMatchFrom: cursor, resultsLimit: resultsLimit)
    }

    @concurrent
    func records(
        for ids: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try await database.records(for: ids, desiredKeys: desiredKeys)
    }

    @concurrent
    func save(_ record: CKRecord) async throws -> CKRecord {
        try await database.save(record)
    }

    @concurrent
    func deleteRecord(withID id: CKRecord.ID) async throws -> CKRecord.ID {
        try await database.deleteRecord(withID: id)
    }
}
