//
//  CloudKitCommunityTransport+PhotoReview.swift
//  OpenHikes
//
//  A reviewer's four verbs, on the contribution pair of record types.
//
//  Split from `CloudKitCommunityTransport+Photos.swift` on the line the other
//  two files are split on: everything there reads a type `_world` may read or
//  writes one `_icloud` may create, and everything here is refused for
//  anybody outside the `reviewer` role. There is no check in this file and
//  nothing about being a reviewer is stored on the device — the server answers
//  these differently depending on who is asking, and that is the whole access
//  control.
//
//  The one edit that is not a create or a delete is
//  ``keepOnlyPhotos(_:ofPending:staging:)``, and it is the second instance of
//  the exception ``CommunitySchema`` documents once: a submission is
//  write-once, except that a reviewer may take individual photographs off one
//  before any published record names it. Everything that makes that safe there
//  makes it safe here, in the same order — one cheap field fetched for a
//  change tag, both photo fields rewritten together because they pair by
//  index, `.changedKeys` so nothing else on the record is touched, and the
//  whole thing done *before* the record is published rather than after.
//

import CloudKit
import CoreLocation
import Foundation
import os

nonisolated extension CloudKitCommunityTransport {

    @concurrent
    func photos(
        ofPending pending: CommunityPendingPhotos,
        downloadingInto directory: URL
    ) async throws -> CommunityPhotoContribution {
        let record: CKRecord
        do {
            // A fetch by record name, never a query:
            // ``CommunitySchema/photoSubmissionType`` carries no index
            // precisely so that pending uploads cannot be enumerated, and an
            // unindexed type can still be fetched by an ID.
            record = try await database.record(
                for: CKRecord.ID(recordName: pending.photoSubmissionID)
            )
        } catch {
            throw Self.failure(from: error, while: "opening contributed photos")
        }

        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let assets = record[CommunitySchema.PhotoSubmission.photos] as? [CKAsset] ?? []
        let decoded = Self.decodePins(
            in: record,
            field: CommunitySchema.PhotoSubmission.photoPins
        )
        try Task.checkCancellation()
        let downloaded = Self.copyPhotos(assets, into: directory)
        if downloaded.count != assets.count {
            Self.logger.error(
                """
                Contributed photos \(pending.id, privacy: .public) kept \
                \(downloaded.count) of \(assets.count).
                """
            )
        }

        return CommunityPhotoContribution(
            // The *notice*'s name while this is still pending, which is what
            // the review screen keys its map preview on. Nothing published
            // exists yet; see ``CommunityPendingPhotos/prospectiveListing``.
            id: pending.id,
            photoSubmissionID: pending.photoSubmissionID,
            authorName: pending.authorName,
            authorID: pending.authorID,
            publishedAt: pending.noticedAt,
            photoPins: Self.pins(
                decoded,
                for: downloaded,
                of: assets.count,
                takenOn: pending.takenOn
            ),
            photoFileURLs: downloaded.map(\.url),
            // What the record carries, which is the number the rewrite has to
            // be judged against — see ``CommunityPhotoContribution/hasEveryPhoto``.
            photosOnRecord: assets.count
        )
    }

    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        ofPending pending: CommunityPendingPhotos,
        staging: URL
    ) async throws {
        try await rewritePhotos(
            of: CKRecord.ID(recordName: pending.photoSubmissionID),
            keeping: kept,
            cheapKey: CommunitySchema.PhotoSubmission.authorName,
            photosField: CommunitySchema.PhotoSubmission.photos,
            pinsField: CommunitySchema.PhotoSubmission.photoPins,
            staging: staging
        )
    }

    @concurrent
    func publishPhotos(
        _ pending: CommunityPendingPhotos
    ) async throws -> CommunityPhotoContribution {
        let record = CKRecord(recordType: CommunitySchema.contributionType)
        record[CommunitySchema.Contribution.photoSubmission] = CKRecord.Reference(
            // `.none`, unlike the notice's back-reference: a published
            // contribution must not be swept away by a delete of the record it
            // names, because taking one down is a decision with an order to it
            // — see ``takeDownPhotos(_:)``.
            recordID: CKRecord.ID(recordName: pending.photoSubmissionID),
            action: .none
        )
        record[CommunitySchema.Contribution.listing] = pending.listingID
        record[CommunitySchema.Contribution.authorName] = pending.authorName
        record[CommunitySchema.Contribution.authorID] = pending.authorID
        record[CommunitySchema.Contribution.photoCount] = Int64(pending.photoCount)
        // Now, not the day the photographs were taken: this field is when they
        // became visible, and it is what orders a hike's contributed sets.
        record[CommunitySchema.Contribution.publishedAt] = Date()

        let saved: CKRecord
        do {
            saved = try await database.save(record)
        } catch {
            throw Self.failure(from: error, while: "publishing contributed photos")
        }

        // Read back through the same initializer the read path uses rather
        // than assembled from what was just written, for the reason
        // ``publish(_:)`` reads its listing back: if what this app wrote cannot
        // survive being read, the photographs are published and invisible, and
        // a reviewer should be told that here rather than find out by opening
        // the hike later.
        guard let entry = ContributionRecord(record: saved) else {
            throw CommunityFailure.unavailable(
                "The photos were published but the record came back unreadable."
            )
        }

        // Live at this point, so a failure past here is not a failed
        // publication and must not be reported as one. What it costs is a
        // queue entry that outlives its approval, which the next look at the
        // queue filters out.
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: pending.id))
        } catch {
            Self.logger.error(
                """
                Published contributed photos but could not clear the queue entry \
                \(pending.id, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }

        return CommunityPhotoContribution(
            id: entry.id,
            photoSubmissionID: entry.photoSubmissionID,
            authorName: entry.authorName,
            authorID: entry.authorID,
            publishedAt: entry.publishedAt,
            // The pictures are on the reviewer's device and on the record;
            // what comes back from here is the decision, not a second download
            // of what they were just looking at.
            photoPins: [],
            photoFileURLs: [],
            photosOnRecord: pending.photoCount
        )
    }

    @concurrent
    func declinePhotos(_ pending: CommunityPendingPhotos) async throws {
        // One delete for both records. The notice holds a `.deleteSelf`
        // reference to the submission, so removing the submission removes the
        // queue entry with it, server-side — the ordering ``decline(_:)``
        // relies on, and for the same reason: a second request is a second
        // thing to fail and would leave, on failing, exactly the orphan this
        // cannot produce.
        do {
            _ = try await database.deleteRecord(
                withID: CKRecord.ID(recordName: pending.photoSubmissionID)
            )
        } catch {
            throw Self.failure(from: error, while: "declining contributed photos")
        }
    }

    @concurrent
    func takeDownPhotos(_ contribution: CommunityPhotoContribution) async throws {
        // The published record first. A failure between the two leaves a
        // submission nobody can reach — unlisted, unenumerable, effectively
        // gone — where the other order would leave photographs on a hike
        // pointing at nothing.
        do {
            _ = try await database.deleteRecord(
                withID: CKRecord.ID(recordName: contribution.id)
            )
        } catch {
            throw Self.failure(from: error, while: "taking contributed photos down")
        }
        do {
            _ = try await database.deleteRecord(
                withID: CKRecord.ID(recordName: contribution.photoSubmissionID)
            )
        } catch {
            Self.logger.error(
                """
                Unlisted contributed photos but could not delete the submission \
                \(contribution.photoSubmissionID, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            throw Self.failure(from: error, while: "deleting a contributed photo submission")
        }
    }

    /// Rewrites a submission's two photo fields so they carry only `kept`.
    ///
    /// One body for both record types, because it is one operation: the two
    /// types spell their photo fields with the same two names and the rewrite
    /// is identical, so a second copy could only ever drift from this one.
    /// What differs is passed in — which record, and which single cheap field
    /// to fetch for a change tag.
    ///
    /// - Parameter cheapKey: One small text field, never the assets. This
    ///   fetch exists to get a record with a current change tag to write
    ///   against; asking for the photographs would download every one of them
    ///   a second time, when the caller has them on disk already and the kept
    ///   ones are about to go back up from exactly those copies.
    func rewritePhotos(
        of id: CKRecord.ID,
        keeping kept: [CommunityKeptPhoto],
        cheapKey: String,
        photosField: String,
        pinsField: String,
        staging: URL
    ) async throws {
        let record: CKRecord
        do {
            let fetched = try await database.records(for: [id], desiredKeys: [cheapKey])
            guard let result = fetched[id] else { throw CommunityFailure.noLongerAvailable }
            record = try result.get()
        } catch {
            throw Self.failure(from: error, while: "reading a submission to edit its photos")
        }

        do {
            if kept.isEmpty {
                // Both fields go, rather than an empty list beside an absent
                // one: a record a reviewer emptied should be indistinguishable
                // from one that arrived with no photographs.
                record[photosField] = nil
                record[pinsField] = nil
            } else {
                let pins = try Self.writeJSON(
                    kept.map(\.pin),
                    named: Self.reviewedPinsFilename,
                    in: staging
                )
                record[photosField] = kept.map(\.fileURL).map(CKAsset.init(fileURL:))
                record[pinsField] = CKAsset(fileURL: pins)
            }
        } catch {
            throw Self.failure(from: error, while: "staging a reviewed submission's photos")
        }

        do {
            // `.changedKeys`, which is what the one-field fetch above is only
            // safe because of: everything else on the record is absent from
            // this copy, and a policy that sent the whole of it would send
            // them as absent.
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
}
