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

import CloudKit
import CoreLocation
import Foundation
import os

nonisolated extension CloudKitCommunityTransport {

    /// Puts a freshly uploaded submission in the reviewer's queue.
    ///
    /// Called by ``CloudKitCommunityTransport/submit(_:)`` and awaited there,
    /// because a submission that never reaches the queue is not *waiting* — it
    /// is lost. Nothing enumerates submissions, by design, so no query can
    /// find one afterwards and no reviewer will ever be shown it, while the
    /// hiker has been told it was sent. That is the one outcome worth failing
    /// a share over.
    ///
    /// The record name goes into the log on the way out, because it is the
    /// only place it will ever appear again: a submission stranded here can be
    /// queued by hand from that line, and without it there is nothing to queue
    /// it *by*.
    func queueForReview(_ submissionID: String) async throws {
        let notice = CKRecord(recordType: CommunitySchema.noticeType)
        notice[CommunitySchema.Notice.submission] = CKRecord.Reference(
            // `.deleteSelf` rather than `.none`, so the queue cannot outlive
            // what it points at: deleting a submission — which is what
            // declining one is — takes its notice with it, server-side, with
            // no second request to fail. See ``decline(_:)``.
            recordID: CKRecord.ID(recordName: submissionID),
            action: .deleteSelf
        )
        do {
            _ = try await database.save(notice)
        } catch {
            Self.logger.error(
                """
                Uploaded a submission but could not queue it for review. \
                It is unreachable until it is queued by hand: \
                \(submissionID, privacy: .public)
                """
            )
            throw Self.failure(from: error, while: "queueing a hike for review")
        }
    }

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

    /// How many notices one look at the queue reads.
    ///
    /// A ceiling rather than a page: the queue is meant to be emptied, and a
    /// reviewer facing more than this has a backlog that a second screenful
    /// would not help with. No cursor is followed, so the oldest fifty are
    /// always the ones shown — which is the right fifty, since the sort is
    /// oldest-first and the 24-hour commitment in `docs/privacy/` is about the
    /// front of the queue rather than the back.
    static var queueLimit: Int { 50 }

    @concurrent
    func pendingSubmissions() async throws -> [CommunityPendingSubmission] {
        let query = CKQuery(
            recordType: CommunitySchema.noticeType,
            predicate: NSPredicate(value: true)
        )
        // The server's own stamp, which is why there is no field to sort on.
        // See ``CommunitySchema`` — a client-written date could put a
        // submission at the front of somebody else's queue.
        query.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let notices: [CKRecord]
        do {
            let (matches, _) = try await database.records(
                matching: query,
                resultsLimit: Self.queueLimit
            )
            notices = matches.compactMap { try? $0.1.get() }
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
        guard !notices.isEmpty else { return [] }

        let submissionIDs = notices.compactMap { notice in
            (notice[CommunitySchema.Notice.submission] as? CKRecord.Reference)?.recordID
        }
        guard !submissionIDs.isEmpty else { return [] }

        let submissions: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            submissions = try await database.records(
                for: submissionIDs,
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

        let alreadyPublished = await publishedSubmissionIDs(among: submissionIDs)

        return notices.compactMap { notice in
            Self.pending(from: notice, in: submissions, skipping: alreadyPublished)
        }
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

    /// Which of `submissionIDs` already have a listing.
    ///
    /// One query rather than one per row, which is what makes the self-healing
    /// above affordable: ``CommunitySchema/Listing/submission`` is QUERYABLE,
    /// so `IN` asks the whole question at once.
    ///
    /// Best effort by design. A failure here means the queue shows a hike that
    /// is already published, which a reviewer can see for themselves on the
    /// screen that opens it — where the alternative, refusing to draw the
    /// queue at all because a tidying query failed, would be the tail wagging
    /// the dog.
    private func publishedSubmissionIDs(
        among submissionIDs: [CKRecord.ID]
    ) async -> Set<CKRecord.ID> {
        let references = submissionIDs.map { CKRecord.Reference(recordID: $0, action: .none) }
        let query = CKQuery(
            recordType: CommunitySchema.listingType,
            predicate: NSPredicate(format: "%K IN %@", CommunitySchema.Listing.submission, references)
        )
        do {
            let (matches, _) = try await database.records(
                matching: query,
                resultsLimit: Self.queueLimit
            )
            return Set(
                matches.compactMap { match in
                    (try? match.1.get())
                        .flatMap { $0[CommunitySchema.Listing.submission] as? CKRecord.Reference }?
                        .recordID
                }
            )
        } catch {
            Self.logger.error(
                """
                Could not check the review queue against published listings: \
                \(error.localizedDescription, privacy: .public)
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
        let id = CKRecord.ID(recordName: pending.submissionID)
        let record: CKRecord
        do {
            // One cheap text field, never the assets. This fetch exists to get
            // a record with a current change tag to write against; asking for
            // the photographs would download every one of them a second time,
            // when the review screen has them on disk already and the kept
            // ones are about to go back up from exactly those copies.
            let fetched = try await database.records(
                for: [id],
                desiredKeys: [CommunitySchema.Submission.title]
            )
            guard let result = fetched[id] else { throw CommunityFailure.noLongerAvailable }
            record = try result.get()
        } catch {
            throw Self.failure(from: error, while: "reading a submission to edit its photos")
        }

        do {
            if kept.isEmpty {
                // Both fields go, rather than an empty list beside an absent
                // one: that is the shape ``stage(_:)`` writes for a hike that
                // never had a photograph, and a submission a reviewer emptied
                // should be indistinguishable from one that arrived empty.
                record[CommunitySchema.Submission.photos] = nil
                record[CommunitySchema.Submission.photoPins] = nil
            } else {
                let pins = try Self.writeJSON(
                    kept.map(\.pin),
                    named: Self.reviewedPinsFilename,
                    in: staging
                )
                record[CommunitySchema.Submission.photos] = kept.map(\.fileURL)
                    .map(CKAsset.init(fileURL:))
                record[CommunitySchema.Submission.photoPins] = CKAsset(fileURL: pins)
            }
        } catch {
            throw Self.failure(from: error, while: "staging a reviewed submission's photos")
        }

        do {
            // `.changedKeys`, which is what the one-field fetch above is only
            // safe because of: the route, the outline, the title and the
            // description are not on this record, and a policy that sent the
            // whole of it would send them as absent. What goes is the two
            // fields set above.
            let (saved, _) = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: true
            )
            if let result = saved[id] { _ = try result.get() }
        } catch {
            throw Self.failure(from: error, while: "removing photos from a submission")
        }
    }

    @concurrent
    func publish(_ pending: CommunityPendingSubmission) async throws -> CommunityListing {
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
                "The hike was published but the listing came back unreadable."
            )
        }

        // The hike is live at this point, so a failure past here is not a
        // failed publication and must not be reported as one. What it costs is
        // a queue entry that outlives its submission's approval, which
        // ``pendingSubmissions()`` filters out on the next look.
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
        do {
            _ = try await database.deleteRecord(
                withID: CKRecord.ID(recordName: listing.submissionID)
            )
        } catch {
            // Unlisted is the part that was asked for and it has happened.
            // What is left is a record nothing can find, which is worth a line
            // in the log because it is the only way it will ever be found.
            Self.logger.error(
                """
                Unlisted a hike but could not delete its submission \
                \(listing.submissionID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
