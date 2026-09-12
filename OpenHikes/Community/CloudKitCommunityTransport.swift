//
//  CloudKitCommunityTransport.swift
//  OpenHikes
//
//  The only file in the app that talks to the public database.
//
//  It is raw CloudKit rather than anything SwiftData does, and that is not a
//  choice so much as the absence of one: SwiftData's mirroring drives the
//  *private* database and offers no hook onto any other, so a public record is
//  a `CKRecord` this app builds, saves and parses by hand. The upside is that
//  the two never meet — nothing here touches the mirrored store, the
//  `ModelContainer`, or anything `CloudSyncCoordinator` reports on.
//
//  Every method is `@concurrent` because every method either blocks on a
//  network round trip or copies image files, and several do both. The
//  container is built inside them for the same reason
//  ``CloudSyncCoordinator/accountStatus(making:)`` builds its own off the main
//  thread: the first `CKContainer(identifier:)` in a process loads CloudKit
//  and shakes hands with its daemon *synchronously*, which on a fresh install
//  is seconds rather than milliseconds. Not cached, deliberately — CloudKit
//  hands back the same instance for an identifier it has already seen, so the
//  cost is paid once per process however often this is called.
//

import CloudKit
import CoreLocation
import Foundation
import os

nonisolated struct CloudKitCommunityTransport: CommunityTransporting {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// The same container the mirrored store uses, and the same one the
    /// entitlement names. The public database inside it is a different
    /// database, not a different container.
    private let containerIdentifier: String

    init(containerIdentifier: String = CloudSyncCoordinator.containerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    private var database: CKDatabase {
        CKContainer(identifier: containerIdentifier).publicCloudDatabase
    }

    // MARK: - Submitting

    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        guard !draft.route.isEmpty else { throw CommunityFailure.nothingToShare }
        // Asked before anything is encoded or uploaded. A signed-out phone can
        // browse perfectly well — public reads need no account — so this is
        // the one place the distinction has to be made, and making it up front
        // is what stops a walker watching a progress spinner for a megabyte of
        // photographs that were never going to be accepted.
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else {
            throw CommunityFailure.notSignedIn
        }

        let record = CKRecord(recordType: CommunitySchema.submissionType)
        record[CommunitySchema.Submission.title] = draft.title
        record[CommunitySchema.Submission.authorName] = draft.authorName
        record[CommunitySchema.Submission.trackDescription] = draft.trackDescription
        record[CommunitySchema.Submission.hikeDate] = draft.hikeDate
        record[CommunitySchema.Submission.distanceMeters] = draft.distanceMeters
        if let start = draft.startCoordinate {
            record[CommunitySchema.Submission.startLocation] = CLLocation(
                latitude: start.latitude,
                longitude: start.longitude
            )
        }

        // The two JSON payloads are written to disk before they are attached,
        // because a `CKAsset` is a file and nothing else. They go beside the
        // re-encoded photographs, in the directory the caller already owns and
        // already deletes — so a failed upload leaves nothing behind here
        // either.
        let workingDirectory = draft.photoFileURLs.first?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        let routeURL = try Self.writeJSON(
            CommunityRouteDocument(route: draft.route),
            named: "route.json",
            in: workingDirectory
        )
        record[CommunitySchema.Submission.route] = CKAsset(fileURL: routeURL)

        if !draft.photoFileURLs.isEmpty {
            let pinsURL = try Self.writeJSON(
                draft.photoPins,
                named: "photoPins.json",
                in: workingDirectory
            )
            record[CommunitySchema.Submission.photoPins] = CKAsset(fileURL: pinsURL)
            record[CommunitySchema.Submission.photos] = draft.photoFileURLs.map(CKAsset.init(fileURL:))
        }

        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            throw Self.failure(from: error, while: "submitting a hike")
        }
    }

    // MARK: - Browsing

    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // CloudKit's own distance operator, which is the only one it has: a
        // bounding box would need four comparisons against two fields and
        // would still be a box. The unit is metres, and the server's own
        // resolution is around ten kilometres — which is why
        // ``CommunityQueryPolicy`` refuses to re-ask for a pan smaller than
        // that would distinguish.
        let predicate = NSPredicate(
            format: "distanceToLocation:fromLocation:(%K, %@) < %f",
            CommunitySchema.Listing.location,
            origin,
            radiusMeters
        )
        let query = CKQuery(recordType: CommunitySchema.listingType, predicate: predicate)
        query.sortDescriptors = [
            CKLocationSortDescriptor(
                key: CommunitySchema.Listing.location,
                relativeLocation: origin
            ),
        ]
        return try await run(
            query,
            limit: limit,
            excluding: excluding,
            reason: "a nearby search"
        )
    }

    @concurrent
    func listings(
        matching query: String,
        area: CommunitySearchArea?,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Full-text rather than `BEGINSWITH`. CloudKit's `BEGINSWITH` is
        // case-sensitive and anchored, so "pilis" would miss "Pilis Ridge"
        // and "ridge" would miss it too — while `self contains` matches
        // tokens case-insensitively against every SEARCHABLE field. It needs
        // the index to exist; see ``CommunitySchema``.
        let titlePredicate = NSPredicate(format: "self contains %@", trimmed)
        let predicate: NSPredicate
        if let area {
            let origin = CLLocation(latitude: area.latitude, longitude: area.longitude)
            let locationPredicate = NSPredicate(
                format: "distanceToLocation:fromLocation:(%K, %@) < %f",
                CommunitySchema.Listing.location,
                origin,
                area.radiusMeters
            )
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [titlePredicate, locationPredicate])
        } else {
            predicate = titlePredicate
        }
        let ckQuery = CKQuery(recordType: CommunitySchema.listingType, predicate: predicate)
        ckQuery.sortDescriptors = [
            NSSortDescriptor(key: CommunitySchema.Listing.publishedAt, ascending: false),
        ]
        return try await run(
            ckQuery,
            limit: limit,
            excluding: excluding,
            reason: "a title search"
        )
    }

    /// Runs a query, following the cursor only as far as blocked rows make
    /// necessary.
    ///
    /// One page when the walker has blocked nobody, which is the ordinary
    /// case and the behaviour this had before: `limit` is already more rows
    /// than fit on a phone, and paging to fill a list nobody scrolls to the
    /// bottom of would spend requests against a shared quota for nothing.
    ///
    /// What changed is that rows are now removed *after* the server has
    /// counted them towards `limit`. A page that comes back entirely from
    /// blocked authors would otherwise draw an empty list with an eligible
    /// hike sitting behind a cursor nobody followed — and asking the same
    /// question again would return the same blocked page. So the exclusion is
    /// applied here, where the cursor still exists, and a page eaten by
    /// blocked rows buys another. ``CommunityPageBudget`` owns how many.
    private func run(
        _ query: CKQuery,
        limit: Int,
        excluding: Set<String>,
        reason: String
    ) async throws -> [CommunityListing] {
        var budget = CommunityPageBudget(limit: limit, excluding: excluding)
        var cursor: CKQueryOperation.Cursor?
        var wantsMore = true
        while wantsMore {
            let fetched = try await page(
                of: query,
                continuing: cursor,
                limit: limit,
                reason: reason
            )
            cursor = fetched.cursor
            wantsMore = budget.accept(fetched.listings, hasMore: fetched.cursor != nil)
        }
        return budget.results
    }

    /// One round trip: the first page of `query`, or the page after `cursor`.
    private func page(
        of query: CKQuery,
        continuing cursor: CKQueryOperation.Cursor?,
        limit: Int,
        reason: String
    ) async throws -> (listings: [CommunityListing], cursor: CKQueryOperation.Cursor?) {
        do {
            let (matches, next) = if let cursor {
                try await database.records(continuingMatchFrom: cursor, resultsLimit: limit)
            } else {
                try await database.records(matching: query, resultsLimit: limit)
            }
            let listings = matches.compactMap { id, result -> CommunityListing? in
                switch result {
                case .success(let record):
                    guard let listing = CommunityListing(record: record) else {
                        // A record that came back whole and still cannot be
                        // drawn: a reviewer published it with a field missing.
                        // Named rather than counted, because the only way to
                        // fix it is to open that record in the Console — and
                        // `authorID` is the likeliest one, since it is the
                        // newest field and the only one that renders nothing.
                        Self.logger.error(
                            """
                            Dropped listing \(id.recordName, privacy: .public) during \
                            \(reason, privacy: .public): a required field is missing.
                            """
                        )
                        return nil
                    }
                    return listing
                case .failure(let error):
                    // One unreadable row is not a failed query. A record the
                    // server could not hand back should cost that row and
                    // nothing else — the same bargain the guard above makes
                    // for one it handed back incomplete.
                    Self.logger.error(
                        """
                        Skipped a listing during \(reason, privacy: .public): \
                        \(error.localizedDescription, privacy: .public)
                        """
                    )
                    return nil
                }
            }
            return (listings, next)
        } catch {
            throw Self.failure(from: error, while: reason)
        }
    }

    // MARK: - Opening

    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        let record: CKRecord
        do {
            // A fetch by record name, and never a query: ``CommunitySchema``
            // keeps ``CommunitySchema/submissionType`` unindexed so that
            // submissions cannot be enumerated, and an unindexed type can
            // still be fetched by an ID. The name comes from the listing a
            // reviewer published, which is the only place it is ever
            // advertised.
            //
            // What comes back is what was approved. The type grants no write
            // permission outside the admin role, so the record cannot have
            // changed since a person looked at it — see *Why nobody may write
            // a submission* in ``CommunitySchema``. And `_world` may read it,
            // which is what makes this work on the signed-out phone the
            // account-free browse flow promises.
            record = try await database.record(
                for: CKRecord.ID(recordName: listing.submissionID)
            )
        } catch {
            throw Self.failure(from: error, while: "opening a shared hike")
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        guard let routeAsset = record[CommunitySchema.Submission.route] as? CKAsset,
              let routeURL = routeAsset.fileURL,
              let routeData = try? Data(contentsOf: routeURL),
              let document = try? JSONDecoder().decode(
                  CommunityRouteDocument.self,
                  from: routeData
              )
        else { throw CommunityFailure.noLongerAvailable }

        let pins = Self.decodePins(in: record)
        let photoURLs = Self.copyPhotos(in: record, into: directory)

        let detail = CommunityHikeDetail(
            listing: listing,
            route: document.route,
            trackDescription: record[CommunitySchema.Submission.trackDescription] as? String,
            photoPins: pins,
            photoFileURLs: photoURLs
        )
        // A hike whose pins and photographs disagree is offered without any
        // pins rather than with the wrong ones. See
        // ``CommunityHikeDetail/isConsistent``: silently pinning a photograph
        // to another photograph's coordinate is the one failure nothing
        // downstream could ever notice.
        guard detail.isConsistent else {
            Self.logger.error(
                """
                Shared hike \(listing.id, privacy: .public) has \
                \(pins.count) pins for \(photoURLs.count) photos; dropping the pins.
                """
            )
            return CommunityHikeDetail(
                listing: listing,
                route: document.route,
                trackDescription: detail.trackDescription,
                photoPins: photoURLs.map { _ in
                    CommunityPhotoPin(capturedAt: listing.hikeDate, coordinate: nil)
                },
                photoFileURLs: photoURLs
            )
        }
        return detail
    }

    private static func decodePins(in record: CKRecord) -> [CommunityPhotoPin] {
        guard let asset = record[CommunitySchema.Submission.photoPins] as? CKAsset,
              let url = asset.fileURL,
              let data = try? Data(contentsOf: url),
              let pins = try? JSONDecoder().decode([CommunityPhotoPin].self, from: data)
        else { return [] }
        return pins
    }

    /// Copies the downloaded assets somewhere this app controls.
    ///
    /// CloudKit hands back a URL into its own cache and is free to delete the
    /// file behind it whenever it likes, so reading from it later — which a
    /// gallery scrolled a minute afterwards certainly is — is reading from a
    /// path that may have gone. Copying is the documented way to keep one.
    private static func copyPhotos(in record: CKRecord, into directory: URL) -> [URL] {
        guard let assets = record[CommunitySchema.Submission.photos] as? [CKAsset] else { return [] }
        return assets.enumerated().compactMap { index, asset in
            guard let source = asset.fileURL else { return nil }
            let destination = directory.appendingPathComponent(
                "photo-\(index).jpeg",
                isDirectory: false
            )
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            } catch {
                logger.error(
                    "Could not keep a downloaded photo: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }

    // MARK: - Plumbing

    private static func writeJSON(
        _ value: some Encodable,
        named name: String,
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        return url
    }

    /// Turns whatever CloudKit threw into one of the five things the app is
    /// allowed to say, keeping the real diagnostic in the log.
    ///
    /// The retryable conditions are folded into one `unreachable` on purpose.
    /// A rate limit, a busy service and a phone in a tunnel are the same
    /// sentence to a walker — *try again* — and telling them apart would only
    /// let the UI offer three wordings of it.
    private static func failure(from error: any Error, while reason: String) -> CommunityFailure {
        if let failure = error as? CommunityFailure { return failure }
        logger.error(
            """
            Community request failed while \(reason, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """
        )
        guard let ckError = error as? CKError else { return .unavailable(error.localizedDescription) }
        // A set rather than a multi-case pattern so the list reads as what it
        // is: the conditions that mean *try again later*, folded into one
        // sentence on purpose. See this function's summary for why a rate
        // limit and a tunnel are not told apart.
        let retryable: Set<CKError.Code> = [
            .networkFailure,
            .networkUnavailable,
            .requestRateLimited,
            .serviceUnavailable,
            .zoneBusy,
        ]
        if retryable.contains(ckError.code) { return .unreachable }
        return switch ckError.code {
        case .notAuthenticated, .managedAccountRestricted: .notSignedIn
        case .unknownItem: .noLongerAvailable
        default: .unavailable(ckError.localizedDescription)
        }
    }
}

// MARK: - Reading a listing

// `nonisolated` on the extension, not decoration: `SWIFT_DEFAULT_ACTOR_ISOLATION
// = MainActor` makes an unannotated extension main-actor isolated, and this
// initializer is called from the `@concurrent` query path.
nonisolated private extension CommunityListing {
    /// Builds a listing from a published record, or `nil` when the record is
    /// missing something the row cannot be drawn without.
    ///
    /// Strict about the fields a row *renders* and forgiving about the rest: a
    /// listing with no cover photo is an ordinary listing, and one with no
    /// location is not — it could never have been found by the query that
    /// returned it, so it is a record somebody built by hand and got wrong.
    ///
    /// ``CommunitySchema/Listing/authorID`` is strict too, and it is the one
    /// entry in that list which renders nothing. A listing without it is one
    /// no walker can block, and App Store Guideline 1.2 has no exemption for a
    /// record the reviewer filled in wrong — so the row is dropped, which
    /// costs that listing and is logged by the caller with the reason. The
    /// alternative is a block keyed on an empty string, which would silently
    /// hide every *other* listing the reviewer forgot the field on.
    init?(record: CKRecord) {
        guard let reference = record[CommunitySchema.Listing.submission] as? CKRecord.Reference,
              let title = record[CommunitySchema.Listing.title] as? String,
              let location = record[CommunitySchema.Listing.location] as? CLLocation,
              let authorID = (record[CommunitySchema.Listing.authorID] as? String)
              .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !authorID.isEmpty
        else { return nil }

        id = record.recordID.recordName
        submissionID = reference.recordID.recordName
        self.title = title
        self.authorID = authorID
        authorName = record[CommunitySchema.Listing.authorName] as? String ?? ""
        hikeDate = record[CommunitySchema.Listing.hikeDate] as? Date ?? .distantPast
        distanceMeters = record[CommunitySchema.Listing.distanceMeters] as? Double ?? 0
        photoCount = Int(record[CommunitySchema.Listing.photoCount] as? Int64 ?? 0)
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        publishedAt = record[CommunitySchema.Listing.publishedAt] as? Date
            ?? record.creationDate
            ?? .distantPast
    }
}
