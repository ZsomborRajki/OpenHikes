//
//  CloudKitCommunityTransport+Reviewing.swift
//  OpenHikes
//
//  The reviewer's half of the conversation with the public database.
//
//  One type with `CloudKitCommunityTransport.swift`, split for length alone —
//  which is the reason `database`, `logger` and `contents` are internal there
//  rather than private, since `private` is file-scoped in Swift.
//
//  What is here is the only part of this feature the server answers
//  differently depending on who is asking. Everything in the other file reads
//  a type `_world` may read or writes one `_icloud` may create; the writes
//  below are refused for everybody outside the `reviewer` role, and the read
//  returns them nothing. That is the whole access control — there is no check
//  in this file, and nothing about being a reviewer is stored anywhere on the
//  device. See ``CommunitySchema`` for why the queue is a third record type
//  rather than an index on the submissions.
//
//  One of those writes edits a submission rather than deleting it —
//  ``keepOnlyPhotos(_:of:staging:)``, which is how a reviewer takes a single
//  photograph off a hike they are otherwise happy to publish. It is the only
//  place in this app that modifies a submission, and ``CommunitySchema``'s
//  argument for a write-once record is what bounds it: it touches the two
//  photo fields, it runs before any listing names the record, and it exists
//  because a picture hidden from a listing is not a picture that has been
//  removed.
//

import Algorithms
import CloudKit
import CoreLocation
import Foundation
import OpenHikesData
import os

nonisolated extension CloudKitCommunityTransport {

    @concurrent
    func detail(
        ofPending pending: CommunityPendingSubmission,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        try await contents(
            of: pending.prospectiveListing,
            downloadingInto: directory
        )
    }

    /// How many entries one look at the queue shows.
    ///
    /// A ceiling rather than a page: the queue is meant to be emptied, and a
    /// reviewer facing more than this has a backlog that a second screenful
    /// would not help with. The oldest fifty are always the ones shown —
    /// which is the right fifty, since the sort is oldest-first and the
    /// 24-hour commitment in `docs/privacy/` is about the front of the queue
    /// rather than the back.
    ///
    /// Fifty entries a reviewer can act on, not fifty notices. See
    /// ``queuePages``.
    static var queueLimit: Int { 50 }

    /// How many pages of notices one look at the queue may read.
    ///
    /// More than one for the reason ``CommunityPageBudget`` exists: notices
    /// are left out after the server has counted them. One whose submission
    /// is already published is the case that matters — the delete after a
    /// publication is allowed to fail, see ``publish(_:)`` — and a single page
    /// could be nothing else. Reading one page and dropping the cursor then
    /// left the work behind it unreachable: every look fetched the same
    /// fifty leftovers and drew an empty queue. So a page spent on them buys
    /// another, asking only for the slots still empty, which keeps the
    /// ceiling and the oldest-first order.
    ///
    /// Four, the browse path's budget, rather than unbounded: a page of
    /// leftovers takes a run of failed deletes, which is rare, and a queue
    /// with none in its first page pays exactly the one read it always did.
    static var queuePages: Int { 4 }

    @concurrent
    func reviewQueue() async throws -> CommunityReviewBatch {
        try await Self.reviewQueue(in: CloudKitReviewDatabase(containerIdentifier: containerIdentifier))
    }

    /// ``reviewQueue()`` against `database`: the public one in the app, a
    /// script in a suite. See ``CommunityReviewDatabase``.
    @concurrent
    static func reviewQueue<Database: CommunityReviewDatabase>(
        in database: Database
    ) async throws -> CommunityReviewBatch {
        let query = CKQuery(
            recordType: CommunitySchema.noticeType,
            predicate: NSPredicate(value: true)
        )
        // The server's own stamp, which is why there is no field to sort on.
        // See ``CommunitySchema`` — a client-written date could put a
        // submission at the front of somebody else's queue. It also orders the
        // two kinds against each other, which is what makes one queue rather
        // than two lists that each claim to be oldest-first.
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var batch = CommunityReviewBatch()
        var cursor: Database.Cursor?
        for page in 1...Self.queuePages {
            let read: (entries: CommunityReviewBatch, next: Database.Cursor?)
            do {
                read = try await queuePage(
                    of: query,
                    after: cursor,
                    slots: Self.queueLimit - batch.count,
                    in: database
                )
            } catch where page > 1 {
                // The first page answers whether this account may read the
                // queue at all, and its failure is thrown — see
                // ``queuePage(of:after:slots:in:)``. A later one fails after
                // that is settled, and what the pages before it found is real
                // work, so it is kept and the next look reads further.
                Self.logger.error(
                    """
                    Stopped reading the review queue after \(page - 1) pages: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                break
            }
            batch.hikes += read.entries.hikes
            batch.photographs += read.entries.photographs
            guard let next = read.next, batch.count < Self.queueLimit else { break }
            cursor = next
        }
        return batch
    }

    /// One page of notices, as the entries a reviewer can act on, and where
    /// the next page starts.
    ///
    /// - Parameter slots: How many entries the queue still has room for, and
    ///   so how many notices this page asks for. A notice makes one entry at
    ///   most, so a page this size cannot overfill the queue, and one read
    ///   after an older page cannot put a newer entry ahead of an older one.
    private static func queuePage<Database: CommunityReviewDatabase>(
        of query: CKQuery,
        after cursor: Database.Cursor?,
        slots: Int,
        in database: Database
    ) async throws -> (entries: CommunityReviewBatch, next: Database.Cursor?) {
        let notices: [CKRecord]
        let next: Database.Cursor?
        do {
            let (matches, following) = if let cursor {
                try await database.records(continuingMatchFrom: cursor, resultsLimit: slots)
            } else {
                try await database.records(matching: query, resultsLimit: slots)
            }
            notices = matches.compactMap { try? $0.1.get() }
            next = following
        } catch {
            // A refusal is reported rather than swallowed, and that is a
            // deliberate change of mind worth the comment. Turning it into an
            // empty list here would have made *a reviewer with nothing to do*
            // and *not a reviewer* the same answer — and the second is the
            // only signal the app has for whether to offer a takedown on a
            // hike that is already published, which no queue row can carry.
            // ``CommunityReviewQueue`` is where the silence lives instead.
            throw Self.failure(from: error, while: "reading the review queue")
        }
        guard !notices.isEmpty else { return (CommunityReviewBatch(), next) }

        // Split by which reference the notice carries, before anything is
        // fetched, because the two kinds are read with different `desiredKeys`
        // off different record types. A notice pointing at neither is dropped
        // here — nothing this app writes produces one, and there is nothing
        // behind it to judge.
        let hikeIDs = Self.referencedIDs(in: notices, field: CommunitySchema.Notice.submission)
        let photoIDs = Self.referencedIDs(
            in: notices,
            field: CommunitySchema.Notice.photoSubmission
        )
        async let hikes = pendingHikes(from: notices, ids: hikeIDs, in: database)
        async let photographs = pendingPhotos(from: notices, ids: photoIDs, in: database)
        return (CommunityReviewBatch(hikes: try await hikes, photographs: try await photographs), next)
    }

    /// The record IDs the notices point at through one of their two reference
    /// fields, deduplicated.
    ///
    /// Deduplicated because two notices can name one record — a queueing that
    /// was retried — and `records(for:)` is keyed by ID, so a duplicate would
    /// cost a slot in the batch and buy nothing.
    private static func referencedIDs(in notices: [CKRecord], field: String) -> [CKRecord.ID] {
        Array(notices.compactMap { ($0[field] as? CKRecord.Reference)?.recordID }.uniqued())
    }

    /// The hike half of one look at the queue.
    private static func pendingHikes(
        from notices: [CKRecord],
        ids: [CKRecord.ID],
        in database: some CommunityReviewDatabase
    ) async throws -> [CommunityPendingSubmission] {
        guard !ids.isEmpty else { return [] }
        let submissions: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            submissions = try await database.records(
                for: ids,
                // Every field the listing needs and not one more. The two
                // asset fields are deliberately absent: asking for `photos`
                // would download every photograph of every hike in the queue
                // to draw a list of titles. It is also why
                // ``CommunityPendingSubmission/photoCount`` starts at zero —
                // the count cannot be known without the assets, so it is
                // filled in by the screen that fetches them.
                desiredKeys: [
                    CommunitySchema.Submission.title,
                    CommunitySchema.Submission.authorName,
                    CommunitySchema.Submission.trackDescription,
                    CommunitySchema.Submission.hikeDate,
                    CommunitySchema.Submission.distanceMeters,
                    CommunitySchema.Submission.startLocation,
                ]
            )
        } catch {
            throw Self.failure(from: error, while: "reading queued submissions")
        }

        let alreadyPublished = await published(
            ids,
            as: CommunitySchema.listingType,
            through: CommunitySchema.Listing.submission,
            in: database
        )
        return notices.compactMap { notice in
            Self.pending(from: notice, in: submissions, skipping: alreadyPublished)
        }
    }

    /// The contribution half of one look at the queue.
    ///
    /// Checked against what is already published, as the hikes above are, and
    /// for a sharper version of their reason. A contribution whose notice
    /// outlived its publication — see ``publishPhotos(_:)``, where the delete
    /// is allowed to fail — has no right answer if it is offered again:
    /// publishing it puts a second copy of the same set on the hike, and
    /// declining it deletes the submission the published set reads its
    /// photographs from. The check costs a reviewer one query for a page that
    /// holds a contribution, and costs everybody else nothing, because their
    /// read of the queue is refused before any of this runs.
    private static func pendingPhotos(
        from notices: [CKRecord],
        ids: [CKRecord.ID],
        in database: some CommunityReviewDatabase
    ) async throws -> [CommunityPendingPhotos] {
        guard !ids.isEmpty else { return [] }
        let submissions: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            submissions = try await database.records(
                for: ids,
                // The assets are absent for the reason they are absent above,
                // and it bites harder here: a contribution is nothing but
                // photographs, so asking for them would make listing the queue
                // and reviewing it the same download.
                desiredKeys: [
                    CommunitySchema.PhotoSubmission.listing,
                    CommunitySchema.PhotoSubmission.authorName,
                    CommunitySchema.PhotoSubmission.takenOn,
                    CommunitySchema.PhotoSubmission.location,
                ]
            )
        } catch {
            throw Self.failure(from: error, while: "reading queued photos")
        }

        let alreadyPublished = await published(
            ids,
            as: CommunitySchema.contributionType,
            through: CommunitySchema.Contribution.photoSubmission,
            in: database
        )
        return notices.compactMap { notice in
            Self.pendingPhotos(from: notice, in: submissions, skipping: alreadyPublished)
        }
    }

    /// One contributed-photo queue entry, or `nil` for a notice there is
    /// nothing to review behind.
    ///
    /// Strict about the target, which is the field with no sensible fallback:
    /// a contribution that does not say which hike it is for is one a reviewer
    /// cannot judge and publishing would put photographs on nothing. The
    /// credit and the place are forgiving, for the reason the hike queue's
    /// are — a contribution with no credit is ordinary, and one with no
    /// coordinate is a set of pictures that will be judged on the pictures.
    private static func pendingPhotos(
        from notice: CKRecord,
        in submissions: [CKRecord.ID: Result<CKRecord, any Error>],
        skipping alreadyPublished: Set<CKRecord.ID>
    ) -> CommunityPendingPhotos? {
        guard let reference = notice[CommunitySchema.Notice.photoSubmission]
            as? CKRecord.Reference,
            let record = try? submissions[reference.recordID]?.get(),
            let listingID = record[CommunitySchema.PhotoSubmission.listing] as? String,
            !listingID.isEmpty,
            // Published already, and the notice outlived it. See
            // ``pendingPhotos(from:ids:in:)`` for why it must not be offered.
            !alreadyPublished.contains(reference.recordID)
        else { return nil }

        let location = record[CommunitySchema.PhotoSubmission.location] as? CLLocation
        return CommunityPendingPhotos(
            id: notice.recordID.recordName,
            photoSubmissionID: reference.recordID.recordName,
            listingID: listingID,
            // Bounded exactly as the hike queue bounds the same field: this
            // text was written by whoever uploaded it, it is rendered on the
            // review screen, and publishing copies it onto the contribution
            // verbatim.
            authorName: BoundedText.boundedOrEmpty(
                record[CommunitySchema.PhotoSubmission.authorName] as? String,
                to: .credit
            ),
            // Stamped by CloudKit and settable by no client. Without it
            // nothing could block the contributor, so a published record
            // carrying an empty one is dropped on the way back in — see
            // ``CloudKitCommunityTransport/ContributionRecord``.
            authorID: record.creatorUserRecordID?.recordName ?? "",
            takenOn: record[CommunitySchema.PhotoSubmission.takenOn] as? Date ?? .distantPast,
            photoCount: 0,
            latitude: location?.coordinate.latitude ?? 0,
            longitude: location?.coordinate.longitude ?? 0,
            noticedAt: notice.creationDate ?? .distantPast
        )
    }

    /// One queue entry, or `nil` for a notice there is nothing to review
    /// behind.
    ///
    /// Split out of the query above for length, and it earns the split: every
    /// decision about whether a notice is *shown* is here, and each one is a
    /// different reason.
    private static func pending(
        from notice: CKRecord,
        in submissions: [CKRecord.ID: Result<CKRecord, any Error>],
        skipping alreadyPublished: Set<CKRecord.ID>
    ) -> CommunityPendingSubmission? {
        guard let reference = notice[CommunitySchema.Notice.submission] as? CKRecord.Reference,
              // A notice whose submission is gone, or whose submission
              // this account could not read. Nothing to review either way,
              // and the notice is left alone rather than tidied up: a
              // fetch that failed for a reason that passes is not grounds
              // for deleting the only pointer to somebody's upload.
              let record = try? submissions[reference.recordID]?.get(),
              // Published already, and the notice outlived its listing's
              // creation — see ``publish(_:)``, where the delete that
              // should have removed it is allowed to fail without failing
              // the publication. Showing it again would invite a second
              // listing for one hike, so the queue heals itself here
              // instead.
              !alreadyPublished.contains(reference.recordID)
        else { return nil }

        return CommunityPendingSubmission(
            id: notice.recordID.recordName,
            submissionID: reference.recordID.recordName,
            // Bounded exactly as ``CommunityListing/init(record:)`` bounds
            // the same fields, and for a sharper version of the same
            // reason: this text was written by whoever uploaded it, it is
            // rendered on the review screen, and publishing copies it onto
            // the listing verbatim. Bounding it here is what stops a
            // submission with a megabyte of title from being the thing a
            // reviewer has to read past.
            title: BoundedText.boundedOrEmpty(
                record[CommunitySchema.Submission.title] as? String,
                to: .title
            ),
            authorName: BoundedText.boundedOrEmpty(
                record[CommunitySchema.Submission.authorName] as? String,
                to: .credit
            ),
            // Stamped by CloudKit and settable by no client, which is what
            // makes it worth carrying: this is the field a reviewer
            // publishing by hand has to copy out of *Created By*, and the
            // one whose absence makes a published hike invisible.
            authorID: record.creatorUserRecordID?.recordName ?? "",
            trackDescription: BoundedText.boundedOrEmpty(
                record[CommunitySchema.Submission.trackDescription] as? String,
                to: .notes
            ),
            hikeDate: record[CommunitySchema.Submission.hikeDate] as? Date ?? .distantPast,
            distanceMeters: record[CommunitySchema.Submission.distanceMeters] as? Double ?? 0,
            photoCount: 0,
            latitude: (record[CommunitySchema.Submission.startLocation] as? CLLocation)?
                .coordinate.latitude ?? 0,
            longitude: (record[CommunitySchema.Submission.startLocation] as? CLLocation)?
                .coordinate.longitude ?? 0,
            noticedAt: notice.creationDate ?? .distantPast
        )
    }

    /// Which of `submissionIDs` a published record of `recordType` already
    /// names through `field`.
    ///
    /// One query rather than one per row, which is what makes the self-healing
    /// above affordable: both back-references —
    /// ``CommunitySchema/Listing/submission`` for a hike and
    /// ``CommunitySchema/Contribution/photoSubmission`` for photographs — are
    /// QUERYABLE, so `IN` asks the whole question at once. It is always the
    /// published type that is asked, never a submission type, whose missing
    /// index is the security control ``CommunitySchema`` describes.
    ///
    /// Best effort by design. A failure here means the queue shows something
    /// that is already published, which a reviewer can see for themselves on
    /// the screen that opens it — where the alternative, refusing to draw the
    /// queue at all because a tidying query failed, would be the tail wagging
    /// the dog.
    private static func published(
        _ submissionIDs: [CKRecord.ID],
        as recordType: String,
        through field: String,
        in database: some CommunityReviewDatabase
    ) async -> Set<CKRecord.ID> {
        let references = submissionIDs.map { CKRecord.Reference(recordID: $0, action: .none) }
        let query = CKQuery(
            recordType: recordType,
            predicate: NSPredicate(format: "%K IN %@", field, references)
        )
        do {
            let (matches, _) = try await database.records(
                matching: query,
                resultsLimit: Self.queueLimit
            )
            return Set(
                matches.compactMap { match in
                    (try? match.1.get())
                        .flatMap { $0[field] as? CKRecord.Reference }?
                        .recordID
                }
            )
        } catch {
            Self.logger.error(
                """
                Could not check the review queue against published \(recordType, privacy: .public) \
                records: \(error.localizedDescription, privacy: .public)
                """
            )
            return []
        }
    }

    /// The rewritten pins file's name, inside the review screen's own
    /// directory.
    ///
    /// Deliberately not `photoPins.json`, which is what
    /// ``CloudKitCommunityTransport/stage(_:)`` writes on the way *up*. These
    /// two never share a directory today, and a name that says which end of
    /// the trip it belongs to is what keeps that from mattering if they ever
    /// do.
    static var reviewedPinsFilename: String { "reviewedPhotoPins.json" }

    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        of pending: CommunityPendingSubmission,
        staging: URL
    ) async throws {
        // One body for both record types — see
        // ``rewritePhotos(of:keeping:cheapKey:photosField:pinsField:staging:)``,
        // which is where the fetch-for-a-change-tag, the paired rewrite and
        // the `.changedKeys` save all live. What differs between the two is
        // which record and which single cheap field to fetch, and both are
        // arguments.
        try await rewritePhotos(
            of: CKRecord.ID(recordName: pending.submissionID),
            keeping: kept,
            cheapKey: CommunitySchema.Submission.title,
            photosField: CommunitySchema.Submission.photos,
            pinsField: CommunitySchema.Submission.photoPins,
            staging: staging
        )
    }

    @concurrent
    func publish(_ pending: CommunityPendingSubmission) async throws -> CommunityListing {
        try await Self.publish(pending, in: CloudKitReviewDatabase(containerIdentifier: containerIdentifier))
    }

    /// ``publish(_:)`` against `database`: the public one in the app, a script
    /// in a suite. See ``CommunityReviewDatabase``.
    @concurrent
    static func publish(
        _ pending: CommunityPendingSubmission,
        in database: some CommunityReviewDatabase
    ) async throws -> CommunityListing {
        let record = CKRecord(recordType: CommunitySchema.listingType)
        record[CommunitySchema.Listing.submission] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: pending.submissionID),
            // `.none`, unlike the notice's back-reference: a listing must not
            // be swept away by a delete of the record it names. Taking a hike
            // down is a decision with an order to it — see ``takeDown(_:)`` —
            // and a cascade would make the order unobservable.
            action: .none
        )
        record[CommunitySchema.Listing.title] = pending.title
        record[CommunitySchema.Listing.authorName] = pending.authorName
        record[CommunitySchema.Listing.authorID] = pending.authorID
        record[CommunitySchema.Listing.hikeDate] = pending.hikeDate
        record[CommunitySchema.Listing.distanceMeters] = pending.distanceMeters
        record[CommunitySchema.Listing.photoCount] = Int64(pending.photoCount)
        record[CommunitySchema.Listing.location] = CLLocation(
            latitude: pending.latitude,
            longitude: pending.longitude
        )
        // Now, not the submission's date: this field is when the hike became
        // visible, and it is the fallback sort for a browse with no location.
        record[CommunitySchema.Listing.publishedAt] = Date()

        let saved: CKRecord
        do {
            saved = try await database.save(record)
        } catch {
            throw Self.failure(from: error, while: "publishing a hike")
        }

        // Read back through the same initializer the browse path uses, rather
        // than assembling a listing from what was just written. If a listing
        // this app built cannot survive ``CommunityListing/init(record:)``,
        // the hike is published and invisible, and a reviewer should be told
        // that here rather than discover it by searching for the hike later.
        guard let listing = CommunityListing(record: saved) else {
            throw CommunityFailure.unavailable(
                String(localized: "The hike was published but the listing came back unreadable.")
            )
        }

        // The hike is live at this point, so a failure past here is not a
        // failed publication and must not be reported as one. What it costs is
        // a queue entry that outlives its submission's approval, which
        // ``reviewQueue()`` filters out on the next look.
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: pending.id))
        } catch {
            Self.logger.error(
                """
                Published a hike but could not clear its queue entry \
                \(pending.id, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return listing
    }

    @concurrent
    func decline(_ pending: CommunityPendingSubmission) async throws {
        // One delete for both records. The notice holds a `.deleteSelf`
        // reference to the submission — see ``submit(_:)`` — so removing the
        // submission removes the queue entry with it, server-side. A second
        // request would be a second thing to fail and would leave, on failing,
        // exactly the orphan this ordering cannot produce.
        do {
            _ = try await database.deleteRecord(
                withID: CKRecord.ID(recordName: pending.submissionID)
            )
        } catch {
            throw Self.failure(from: error, while: "declining a submission")
        }
    }

    @concurrent
    func takeDown(_ listing: CommunityListing) async throws {
        // The listing first. A failure between the two leaves a submission
        // nobody can reach — unlisted, unenumerable, effectively gone — where
        // the other order would leave a listing on the map pointing at nothing
        // and a preview that fails for everybody who taps it.
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: listing.id))
        } catch {
            throw Self.failure(from: error, while: "taking a hike down")
        }
        // `MergedCommunityTransport.takeDown(_:)` refuses a curated listing
        // before it reaches here, and ``CommunityHikeView`` does not offer the
        // action for one. This is the third guard, and the cheapest: a listing
        // with no submission has nothing left to delete, and the unlisting
        // above is the whole of what a takedown could mean for it.
        guard let submissionID = listing.submissionID else { return }
        do {
            _ = try await database.deleteRecord(
                withID: CKRecord.ID(recordName: submissionID)
            )
        } catch {
            // Unlisted is the part that was asked for and it has happened.
            // What is left is a record nothing can find, which is worth a line
            // in the log because it is the only way it will ever be found.
            Self.logger.error(
                """
                Unlisted a hike but could not delete its submission \
                \(submissionID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
