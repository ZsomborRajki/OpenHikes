//
//  CloudKitCommunityTransport+Photos.swift
//  OpenHikes
//
//  The half of the conversation that is about photographs offered to a hike
//  somebody else's trail already stands for.
//
//  One type with `CloudKitCommunityTransport.swift`, split for length — the
//  reason `database`, `logger`, `copyPhotos`, `writeJSON` and `failure` are
//  internal there rather than private.
//
//  Everything here is a second instance of a pattern the other two files
//  already established, and the value of the split is that the second instance
//  can be read beside the first rather than woven into it:
//
//  - ``submitPhotos(_:)`` is ``CloudKitCommunityTransport/submit(_:)`` with no
//    route asset and a string where a reference would be, and it queues the
//    notice in the same breath and for the same reason;
//  - ``contributedPhotos(for:excluding:downloadingInto:)`` is the browse
//    query and the detail fetch in one, because a hike's contributions are
//    two requests whichever way they are asked for and one open is what pays
//    for them;
//  - ``publishPhotos(_:)``, ``declinePhotos(_:)`` and
//    ``takeDownPhotos(_:)`` are the reviewer's three verbs again, on the other
//    pair of record types and in the same orders.
//
//  ## The one genuinely new thing: the target is a string
//
//  ``CommunitySchema/PhotoSubmission/listing`` and
//  ``CommunitySchema/Contribution/listing`` hold a ``CommunityIdentity``
//  rather than a `CKRecord.Reference`, which is what lets an OpenStreetMap
//  relation — a trail with no record anywhere in this database — be a target.
//  Two consequences follow and both are deliberate. Nothing cascades: taking
//  down the hike does not take down its contributions, so a reviewer removing
//  a listing leaves photographs that are unreachable rather than dangling,
//  which is the same end state declining already produces. And the browse
//  query is a string equality on a QUERYABLE field rather than a reference
//  match.
//
//  ``contributionType`` carries a second queryable field beside it —
//  ``CommunitySchema/Contribution/photoSubmission``, which
//  ``contribution(of:)`` asks *has mine been published yet* on. Both indexes
//  are named in ``CommunitySchema``'s header, and a deployment that imports
//  only the first leaves that question failing with `invalidArguments` and a
//  contributor's own screen saying *waiting for review* for good.
//

import CloudKit
import CoreLocation
import Foundation
import os

nonisolated extension CloudKitCommunityTransport {

    // MARK: - Contributing

    @concurrent
    func submitPhotos(_ draft: CommunityPhotoDraft) async throws -> String {
        guard !draft.photoFileURLs.isEmpty else { throw CommunityFailure.noPhotosToShare }
        // Asked before anything is uploaded, for the reason ``submit(_:)``
        // asks it there: a signed-out phone browses perfectly well, and the
        // one thing it cannot do is write.
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else {
            throw CommunityFailure.notSignedIn
        }

        let record = CKRecord(recordType: CommunitySchema.photoSubmissionType)
        record[CommunitySchema.PhotoSubmission.listing] = draft.target.listingID
        record[CommunitySchema.PhotoSubmission.authorName] = draft.authorName
        record[CommunitySchema.PhotoSubmission.takenOn] = draft.takenOn
        if let start = draft.startCoordinate {
            record[CommunitySchema.PhotoSubmission.location] = CLLocation(
                latitude: start.latitude,
                longitude: start.longitude
            )
        }

        do {
            // The pins go to disk before they are attached, because a
            // `CKAsset` is a file and nothing else — into the staging
            // directory the draft names, which the publisher created for this
            // attempt alone and deletes however the attempt ends.
            let pins = try Self.writeJSON(
                draft.photoPins,
                named: "photoPins.json",
                in: draft.stagingDirectory
            )
            record[CommunitySchema.PhotoSubmission.photoPins] = CKAsset(fileURL: pins)
            record[CommunitySchema.PhotoSubmission.photos] = draft.photoFileURLs
                .map(CKAsset.init(fileURL:))
        } catch {
            throw Self.failure(from: error, while: "staging contributed photos")
        }

        let submissionID: String
        do {
            submissionID = try await database.save(record).recordID.recordName
        } catch {
            throw Self.failure(from: error, while: "contributing photos")
        }

        // A contribution nobody is told about is lost rather than waiting, the
        // rule ``CloudKitCommunityTransport/queueForReview(_:)`` states — and
        // sharper here, because a photo submission has no listing that could
        // ever lead back to it.
        try await queuePhotosForReview(submissionID)
        return submissionID
    }

    /// Puts a freshly uploaded contribution in the reviewer's queue.
    ///
    /// The same notice type a hike's submission is queued through, with the
    /// other reference field set — see ``CommunitySchema/Notice`` for why one
    /// type carries both. The record name goes into the log on the way out for
    /// the reason it does there: it is the only place it will ever appear
    /// again.
    private func queuePhotosForReview(_ photoSubmissionID: String) async throws {
        let notice = CKRecord(recordType: CommunitySchema.noticeType)
        notice[CommunitySchema.Notice.photoSubmission] = CKRecord.Reference(
            // `.deleteSelf`, so declining — which is deleting the submission —
            // takes the queue entry with it server-side, with no second
            // request to fail.
            recordID: CKRecord.ID(recordName: photoSubmissionID),
            action: .deleteSelf
        )
        do {
            _ = try await database.save(notice)
        } catch {
            Self.logger.error(
                """
                Uploaded contributed photos but could not queue them for review. \
                They are unreachable until queued by hand: \
                \(photoSubmissionID, privacy: .public)
                """
            )
            throw Self.failure(from: error, while: "queueing photos for review")
        }
    }

    @concurrent
    func contribution(of photoSubmissionID: String) async throws -> String? {
        let reference = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: photoSubmissionID),
            action: .none
        )
        let query = CKQuery(
            recordType: CommunitySchema.contributionType,
            predicate: NSPredicate(
                format: "%K == %@",
                CommunitySchema.Contribution.photoSubmission,
                reference
            )
        )
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: 1)
            return try matches.first?.1.get().recordID.recordName
        } catch {
            throw Self.failure(from: error, while: "checking whether photos are published")
        }
    }

    // MARK: - Reading a hike's contributions

    /// How many published sets one hike's query may return.
    ///
    /// A ceiling rather than a page, for the reason the review queue has one:
    /// nothing is waiting on the twenty-first set, and there is no *More*
    /// button for a cursor to serve. The cursor is followed for one thing
    /// only — pages eaten by blocked contributors, see
    /// ``sets(matching:excluding:)`` — and never to hand back more than this.
    /// The oldest are the ones kept, so a hike's gallery does not reshuffle
    /// under somebody who scrolls back.
    static var maximumContributions: Int { 20 }

    /// How many contributed photographs one hike may **download**.
    ///
    /// The set count above bounds the query and does not bound the transfer,
    /// and the two are very different numbers: a contribution may carry
    /// ``CommunityPublisher/maximumPhotos`` pictures, so twenty sets is
    /// hundreds of assets and hundreds of megabytes for one tap on a row. That
    /// is the whole reason this exists, and why it is applied *before* the
    /// fetch rather than to what comes back — a budget spent after the
    /// download has already been paid is not a budget.
    ///
    /// Sixty, which is well past what anybody pages through and comfortably
    /// more than a hike's own author may publish. It is checked against
    /// ``CommunitySchema/Contribution/photoCount``, which is on the published
    /// record precisely so this question can be asked without the assets, and
    /// a set that would overflow **stops** the list rather than being skipped:
    /// skipping would let a later, smaller set jump ahead of an earlier one
    /// and make a hike's gallery depend on what happened to fit.
    static var maximumContributedPhotos: Int { 60 }

    @concurrent
    func contributedPhotos(
        for listingID: String,
        excluding: Set<String>,
        downloadingInto directory: URL
    ) async throws -> [CommunityPhotoContribution] {
        let query = CKQuery(
            recordType: CommunitySchema.contributionType,
            predicate: NSPredicate(
                format: "%K == %@",
                CommunitySchema.Contribution.listing,
                listingID
            )
        )
        // Oldest first, so a set that is published today lands at the end of
        // the gallery rather than in the middle of it.
        query.sortDescriptors = [
            NSSortDescriptor(key: CommunitySchema.Contribution.publishedAt, ascending: true)
        ]

        let published: [ContributionRecord]
        do {
            // Before the fetch below, which is where the exclusion set has to
            // be applied for a block to mean anything about a stranger's
            // pictures: the download is the cost. See ``sets(matching:excluding:)``.
            published = Self.withinBudget(try await sets(matching: query, excluding: excluding))
        } catch {
            throw Self.failure(from: error, while: "reading a hike's contributed photos")
        }
        guard !published.isEmpty else { return [] }

        try Task.checkCancellation()
        let submissionIDs = published.map { CKRecord.ID(recordName: $0.photoSubmissionID) }
        let submissions: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            // One fetch for every set on the hike. The assets come with it —
            // unlike the queue's fetch, which asks for text only, this *is*
            // the download.
            submissions = try await database.records(for: submissionIDs)
        } catch {
            throw Self.failure(from: error, while: "downloading a hike's contributed photos")
        }

        // Again before the files, the guard ``contents(of:downloadingInto:)``
        // states: a hiker who backed out must not have a stranger's
        // photographs written into a directory their screen has already
        // deleted.
        try Task.checkCancellation()
        return published.compactMap { entry in
            guard let record = try? submissions[CKRecord.ID(recordName: entry.photoSubmissionID)]?
                .get()
            else { return nil }
            return Self.contribution(entry, from: record, downloadingInto: directory)
        }
    }

    /// The published sets on this hike that the hiker is allowed to see, in
    /// the order the server returned them.
    ///
    /// Paged rather than a single request, and for the reason
    /// ``CommunityPageBudget`` exists: the exclusion cannot go into the
    /// predicate, because ``CommunitySchema/Contribution/authorID`` is
    /// deliberately unindexed — indexing it would let anybody enumerate one
    /// person's contributions — so blocked sets are removed *after* the
    /// server has already counted them towards ``maximumContributions``. One
    /// contributor with twenty sets on a trail would otherwise hide every
    /// other contributor's photographs there, permanently and with no way
    /// back.
    ///
    /// A hiker who has blocked nobody pays exactly one request, as this
    /// always did: the first page satisfies the limit and nothing asks for a
    /// second.
    private func sets(
        matching query: CKQuery,
        excluding: Set<String>
    ) async throws -> [ContributionRecord] {
        var budget = CommunityPageBudget<ContributionRecord>(
            limit: Self.maximumContributions,
            excluding: excluding
        )
        var cursor: CKQueryOperation.Cursor?
        var wantsMore = true
        while wantsMore {
            let (matches, next) = if let cursor {
                try await database.records(
                    continuingMatchFrom: cursor,
                    resultsLimit: Self.maximumContributions
                )
            } else {
                try await database.records(
                    matching: query,
                    resultsLimit: Self.maximumContributions
                )
            }
            cursor = next
            wantsMore = budget.accept(
                matches
                    .compactMap { try? $0.1.get() }
                    .compactMap(ContributionRecord.init(record:)),
                hasMore: next != nil
            )
        }
        return budget.results
    }

    /// One published set, with its photographs copied somewhere this app
    /// controls.
    ///
    /// Each set gets a directory of its own inside the screen's, because the
    /// files are named by their index on the record and two sets would
    /// otherwise write `photo-0.jpeg` over each other. The directory is named
    /// for the contribution so a person looking at what a preview left behind
    /// can tell whose pictures are whose.
    private static func contribution(
        _ entry: ContributionRecord,
        from record: CKRecord,
        downloadingInto parent: URL
    ) -> CommunityPhotoContribution? {
        let directory = parent.appending(
            path: "contributed-\(entry.id)",
            directoryHint: .isDirectory
        )
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else { return nil }

        let assets = record[CommunitySchema.PhotoSubmission.photos] as? [CKAsset] ?? []
        // Named for what it is rather than `pins`, which is the static
        // function two lines down: a local of the same name would shadow it.
        let decoded = decodePins(in: record, field: CommunitySchema.PhotoSubmission.photoPins)
        let downloaded = copyPhotos(assets, into: directory)
        guard !downloaded.isEmpty else { return nil }
        if downloaded.count != assets.count {
            logger.error(
                """
                Contributed photos \(entry.id, privacy: .public) kept \
                \(downloaded.count) of \(assets.count).
                """
            )
        }
        return CommunityPhotoContribution(
            id: entry.id,
            photoSubmissionID: entry.photoSubmissionID,
            authorName: entry.authorName,
            authorID: entry.authorID,
            publishedAt: entry.publishedAt,
            // The same index pairing a submission's own photographs use, and
            // the same all-or-nothing fallback when the record's two fields
            // genuinely disagree in length. See ``pins(_:for:of:takenOn:)``.
            photoPins: pins(
                decoded,
                for: downloaded,
                of: assets.count,
                takenOn: entry.publishedAt
            ),
            photoFileURLs: downloaded.map(\.url),
            // Carried even on the read path, where nothing rewrites anything,
            // because it is what tells a hiker's screen apart from a
            // reviewer's: the same value is the guard on the one that can
            // edit, and a type whose field means something only half the time
            // is a type the next reader has to check.
            photosOnRecord: assets.count
        )
    }

    /// The sets that fit inside ``maximumContributedPhotos``, oldest first.
    ///
    /// A prefix rather than a filter, for the reason stated on that constant:
    /// a hike's gallery must not depend on which sets happened to fit. The
    /// first set is always taken however large it is, because a hike whose
    /// only contribution is over the budget would otherwise show nothing at
    /// all and say nothing about why.
    ///
    /// Internal rather than private so a suite can hold it to account: what it
    /// decides is invisible in the result, and the fetch around it needs the
    /// public database.
    static func withinBudget(_ published: [ContributionRecord]) -> [ContributionRecord] {
        var total = 0
        var kept: [ContributionRecord] = []
        for entry in published {
            guard kept.isEmpty || total + entry.photoCount <= maximumContributedPhotos else {
                logger.debug(
                    """
                    Stopped at \(kept.count) contributed sets for this hike: \
                    the next would take it past \(maximumContributedPhotos) photos.
                    """
                )
                break
            }
            total += entry.photoCount
            kept.append(entry)
        }
        return kept
    }

    /// What a published contribution record says, before its photographs have
    /// been fetched.
    ///
    /// Its own value rather than a half-filled ``CommunityPhotoContribution``,
    /// because the difference between the two is exactly the download — and a
    /// type that could exist with no pictures in it would be a type every
    /// screen had to check.
    struct ContributionRecord: CommunityBlockableRow, Sendable {
        var id: String
        var photoSubmissionID: String
        var authorName: String
        var authorID: String
        var publishedAt: Date
        /// How many photographs the reviewer watched arrive and published.
        ///
        /// Read *before* the assets, which is the only thing it is for: it is
        /// what lets ``maximumContributedPhotos`` bound a download rather than
        /// describe one. Nothing draws it — the gallery counts the files that
        /// actually came back.
        var photoCount: Int

        /// ``CommunityBlockableRow``'s one requirement, and never `nil` here:
        /// a contribution with no author is dropped by the initializer below,
        /// exactly as a listing with no author is. There is no curated case on
        /// this type — a set of photographs always came from somebody.
        var blockableAuthorID: String? { authorID }

        /// Spelled out rather than synthesized, because the failable
        /// initializer below suppresses the memberwise one — and this is what
        /// `CommunityContributionBudgetTests` builds a record with. That suite
        /// exists because what ``withinBudget(_:)`` decides is invisible in
        /// the result, and a `CKRecord` is not something it can make.
        init(
            id: String,
            photoSubmissionID: String,
            authorName: String,
            authorID: String,
            publishedAt: Date,
            photoCount: Int
        ) {
            self.id = id
            self.photoSubmissionID = photoSubmissionID
            self.authorName = authorName
            self.authorID = authorID
            self.publishedAt = publishedAt
            self.photoCount = photoCount
        }

        /// Strict about ``CommunitySchema/Contribution/authorID`` for the
        /// reason ``CommunityListing/init(record:)`` is strict about the
        /// listing's: a set nobody can block is one Guideline 1.2 has no
        /// exemption for, and it renders nothing, so a missing one would be
        /// invisible rather than obvious. Dropped, and the row it costs is a
        /// set of photographs rather than a hike.
        init?(record: CKRecord) {
            guard let reference = record[CommunitySchema.Contribution.photoSubmission]
                as? CKRecord.Reference,
                let creator = (record[CommunitySchema.Contribution.authorID] as? String)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
                !creator.isEmpty
            else { return nil }
            id = record.recordID.recordName
            photoSubmissionID = reference.recordID.recordName
            authorID = creator
            // Bounded for the reason every other piece of a stranger's text
            // that this app renders is: it was typed into a public database by
            // whoever uploaded it.
            authorName = BoundedText.boundedOrEmpty(
                record[CommunitySchema.Contribution.authorName] as? String,
                to: .credit
            )
            publishedAt = record[CommunitySchema.Contribution.publishedAt] as? Date
                ?? record.creationDate
                ?? .distantPast
            // A record with no count is one written before the field existed
            // or by hand in the Console. Zero rather than a guess: it costs
            // this set nothing of the budget, which errs towards showing the
            // photographs rather than towards hiding them.
            photoCount = Int(record[CommunitySchema.Contribution.photoCount] as? Int64 ?? 0)
        }
    }
}
