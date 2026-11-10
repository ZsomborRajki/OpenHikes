//
//  ScriptedReviewDatabase.swift
//  OpenHikesTests
//
//  The seam under the reviewer's queue, scripted: an in-memory stand-in for
//  the public database that the real queue read and the real publications run
//  against, and that refuses exactly the requests a suite tells it to.
//

import CloudKit
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

/// A `CommunityReviewDatabase` holding a handful of records in memory.
///
/// It stands in for the public database, which no suite may reach: a record
/// saved from a test run is one every user can see. It answers only the
/// queries the schema has an index for — every notice, oldest first; listings
/// by `submission`; contributions by `photoSubmission` — and refuses any other
/// with `invalidArguments`, which is what the server answers for a query
/// against a field with no index. A query on a submission type is therefore
/// refused here exactly as it would be there, and recorded as an issue, since
/// running one would be the security control in ``CommunitySchema`` failing.
///
/// The records are kept in the order they were added, which stands for the
/// server's `___createTime`: a record made here has no creation date.
nonisolated final class ScriptedReviewDatabase: CommunityReviewDatabase {
    /// Where a query's next page starts: the query, and how much of its
    /// answer the pages before have returned.
    nonisolated struct Cursor: Sendable {
        let query: CKQuery
        let offset: Int
    }

    /// One request the transport made, in the order it made it.
    nonisolated enum Request: Equatable, Sendable {
        /// A page of a query: the type asked about and how many rows it asked
        /// for. A continuation is a page like any other.
        case query(recordType: String, resultsLimit: Int)
        case fetch(recordNames: [String])
        case save(recordType: String)
        case delete(recordName: String)
    }

    nonisolated private struct State {
        var records: [CKRecord]
        var requests: [Request] = []
        var refusedDeletes: [String: CKError] = [:]
        var refusedQueries: [String: CKError] = [:]
        /// Keyed by which page of the notice query it refuses, counting from
        /// zero across every look.
        var refusedNoticePages: [Int: CKError] = [:]
        var noticePagesRead = 0
    }

    private let state: Mutex<State>

    init(records: [CKRecord] = []) {
        state = Mutex(State(records: records))
    }

    /// Adds records after any already here, so they are newer than all of them.
    func insert(_ records: [CKRecord]) {
        state.withLock { $0.records += records }
    }

    /// Refuses every delete of `recordNames` from now on.
    func refuseDeletes(of recordNames: [String], with error: CKError) {
        state.withLock { held in
            for name in recordNames { held.refusedDeletes[name] = error }
        }
    }

    /// Refuses every query of `recordType` from now on.
    func refuseQueries(of recordType: String, with error: CKError) {
        state.withLock { $0.refusedQueries[recordType] = error }
    }

    /// Refuses the page of the notice query that is `page` pages from now,
    /// counting the next one as zero.
    func refuseNoticePage(_ page: Int, with error: CKError) {
        state.withLock { $0.refusedNoticePages[$0.noticePagesRead + page] = error }
    }

    /// Every request so far, refused ones included.
    var requests: [Request] {
        state.withLock { $0.requests }
    }

    /// Whether a record of this name is still here.
    func contains(_ recordName: String) -> Bool {
        state.withLock { held in held.records.contains { $0.recordID.recordName == recordName } }
    }

    /// The names of every record of `recordType`, oldest first.
    func recordNames(of recordType: String) -> [String] {
        state.withLock { held in
            held.records.filter { $0.recordType == recordType }.map(\.recordID.recordName)
        }
    }

    /// Clears the request log, so a suite can count what one look costs.
    func forgetRequests() {
        state.withLock { $0.requests = [] }
    }

    @concurrent
    func records(matching query: CKQuery, resultsLimit: Int) async throws -> Page {
        try page(of: Cursor(query: query, offset: 0), resultsLimit: resultsLimit)
    }

    @concurrent
    func records(continuingMatchFrom cursor: Cursor, resultsLimit: Int) async throws -> Page {
        try page(of: cursor, resultsLimit: resultsLimit)
    }

    @concurrent
    func records(
        for ids: [CKRecord.ID],
        desiredKeys: [CKRecord.FieldKey]
    ) async -> [CKRecord.ID: Result<CKRecord, any Error>] {
        state.withLock { held in
            held.requests.append(.fetch(recordNames: ids.map(\.recordName)))
            var found: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
            for id in ids {
                if let record = held.records.first(where: { $0.recordID == id }) {
                    found[id] = .success(record)
                } else {
                    found[id] = .failure(CKError(.unknownItem))
                }
            }
            return found
        }
    }

    @concurrent
    func save(_ record: CKRecord) async -> CKRecord {
        state.withLock { held in
            held.requests.append(.save(recordType: record.recordType))
            held.records.removeAll { $0.recordID == record.recordID }
            held.records.append(record)
        }
        return record
    }

    @concurrent
    func deleteRecord(withID id: CKRecord.ID) async throws -> CKRecord.ID {
        try state.withLock { held in
            held.requests.append(.delete(recordName: id.recordName))
            if let refusal = held.refusedDeletes[id.recordName] { throw refusal }
            guard held.records.contains(where: { $0.recordID == id }) else { throw CKError(.unknownItem) }
            held.records.removeAll { $0.recordID == id }
            return id
        }
    }

    private func page(of cursor: Cursor, resultsLimit: Int) throws -> Page {
        try state.withLock { held in
            let query = cursor.query
            held.requests.append(.query(recordType: query.recordType, resultsLimit: resultsLimit))
            if query.recordType == CommunitySchema.noticeType {
                let page = held.noticePagesRead
                held.noticePagesRead += 1
                if let refusal = held.refusedNoticePages[page] { throw refusal }
            }
            if let refusal = held.refusedQueries[query.recordType] { throw refusal }
            guard let matches = Self.matcher(for: query) else {
                Issue.record("The review queue ran a query the schema has no index for: \(query)")
                throw CKError(.invalidArguments)
            }
            let answer = held.records.filter(matches)
            let page = answer.dropFirst(cursor.offset).prefix(resultsLimit)
            let end = cursor.offset + page.count
            return (
                matchResults: page.map { ($0.recordID, .success($0)) },
                queryCursor: end < answer.count ? Cursor(query: query, offset: end) : nil
            )
        }
    }

    /// The test a record must pass to be in `query`'s answer, or `nil` for a
    /// query the public database would refuse.
    private static func matcher(for query: CKQuery) -> ((CKRecord) -> Bool)? {
        let recordType = query.recordType
        let isOfType: (CKRecord) -> Bool = { $0.recordType == recordType }
        switch recordType {
        case CommunitySchema.noticeType:
            return query.predicate.predicateFormat == "TRUEPREDICATE" ? isOfType : nil
        case CommunitySchema.listingType:
            return referenceMatcher(for: query, field: CommunitySchema.Listing.submission, isOfType)
        case CommunitySchema.contributionType:
            return referenceMatcher(for: query, field: CommunitySchema.Contribution.photoSubmission, isOfType)
        default:
            return nil
        }
    }

    /// `field IN references`, which is the one predicate the queue asks of a
    /// published type.
    private static func referenceMatcher(
        for query: CKQuery,
        field: String,
        _ isOfType: @escaping (CKRecord) -> Bool
    ) -> ((CKRecord) -> Bool)? {
        guard let comparison = query.predicate as? NSComparisonPredicate,
              comparison.predicateOperatorType == .in,
              comparison.leftExpression.keyPath == field,
              let references = comparison.rightExpression.constantValue as? [CKRecord.Reference]
        else { return nil }
        let wanted = Set(references.map(\.recordID))
        return { record in
            guard isOfType(record), let reference = record[field] as? CKRecord.Reference else { return false }
            return wanted.contains(reference.recordID)
        }
    }
}

/// The records an upload leaves in the public database, built the way the
/// transport builds them.
enum ReviewQueueFixture {
    /// The notice's name for `submissionID`, which is what a publication's
    /// cleanup deletes.
    static func noticeName(for submissionID: String) -> String {
        CommunitySchema.Notice.recordName(forSubmission: submissionID)
    }

    /// A hike submission and the notice queueing it.
    static func hike(_ submissionID: String) -> [CKRecord] {
        let submission = CKRecord(
            recordType: CommunitySchema.submissionType,
            recordID: CKRecord.ID(recordName: submissionID)
        )
        submission[CommunitySchema.Submission.title] = submissionID
        submission[CommunitySchema.Submission.authorName] = "Anna"
        return [submission, notice(for: submissionID, through: CommunitySchema.Notice.submission)]
    }

    /// A photo submission aimed at `listingID`, and the notice queueing it.
    static func photos(_ submissionID: String, onto listingID: String = "listing-1") -> [CKRecord] {
        let submission = CKRecord(
            recordType: CommunitySchema.photoSubmissionType,
            recordID: CKRecord.ID(recordName: submissionID)
        )
        submission[CommunitySchema.PhotoSubmission.listing] = listingID
        submission[CommunitySchema.PhotoSubmission.authorName] = "Aino"
        return [submission, notice(for: submissionID, through: CommunitySchema.Notice.photoSubmission)]
    }

    /// The listing publishing `submissionID` leaves behind, with the
    /// back-reference ``CloudKitCommunityTransport/publish(_:)`` writes.
    static func listing(publishing submissionID: String) -> CKRecord {
        let listing = CKRecord(recordType: CommunitySchema.listingType)
        listing[CommunitySchema.Listing.submission] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: submissionID),
            action: .none
        )
        listing[CommunitySchema.Listing.authorID] = "author-\(submissionID)"
        return listing
    }

    /// The contribution publishing `photoSubmissionID` leaves behind, with the
    /// back-reference ``CloudKitCommunityTransport/publishPhotos(_:)`` writes.
    static func contribution(publishing photoSubmissionID: String) -> CKRecord {
        let contribution = CKRecord(recordType: CommunitySchema.contributionType)
        contribution[CommunitySchema.Contribution.photoSubmission] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: photoSubmissionID),
            action: .none
        )
        contribution[CommunitySchema.Contribution.authorID] = "author-\(photoSubmissionID)"
        return contribution
    }

    /// `row` as the server would have handed it over.
    ///
    /// The author is stamped by CloudKit on a real submission and no record
    /// made on a device can carry it, so a row read from these records has
    /// none — and a publication without one comes back unreadable, by design.
    static func stamped(_ row: CommunityPendingSubmission) -> CommunityPendingSubmission {
        var row = row
        row.authorID = "author-\(row.submissionID)"
        return row
    }

    /// The same stamp, on contributed photographs.
    static func stamped(_ row: CommunityPendingPhotos) -> CommunityPendingPhotos {
        var row = row
        row.authorID = "author-\(row.photoSubmissionID)"
        return row
    }

    private static func notice(for submissionID: String, through field: String) -> CKRecord {
        let notice = CKRecord(
            recordType: CommunitySchema.noticeType,
            recordID: CKRecord.ID(recordName: noticeName(for: submissionID))
        )
        notice[field] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: submissionID),
            action: .deleteSelf
        )
        return notice
    }
}

nonisolated private extension CKError {
    /// `CKError` has no public initializer, and a real one needs the service —
    /// the same shape ``CommunityFailureMappingTests`` builds. Nonisolated,
    /// because the database answers off the main actor.
    init(_ code: Code) {
        self.init(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
    }
}
