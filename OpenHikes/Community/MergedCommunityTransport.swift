//
//  MergedCommunityTransport.swift
//  OpenHikes
//
//  The community list has two sources now, and this is the only place that
//  knows it.
//
//  A ``CommunityTransporting`` that holds the CloudKit one and a
//  ``CuratedTrailSourcing``, rather than teaching ``CommunityBrowser`` about a
//  second source. The browser is 1,025 lines and already parameterised on a
//  two-case question with two task handles, two accept branches and two fail
//  branches; a third would touch every one of them. Nothing above this line
//  has to change, and nothing above this line can tell there are two.
//
//  ## Three rules, and each of them is a correction to the obvious version
//
//  **A published hike never loses its place to a curated one.** The limit is
//  spent on CloudKit first and only the remainder is asked of Overpass. The
//  obvious version — ask both for the full page and truncate — would push real
//  people's hikes off the bottom of the list as soon as an area had twenty-five
//  waymarked routes in it, which in the Alps is most areas. The feature exists
//  so the list is not empty, not so it is full.
//
//  **One source failing is not the answer failing.** ``CommunityBrowser/state``
//  describes the nearby request as a whole, and a `.failed` draws *These are
//  the hikes from the last search that worked* over the whole list. Overpass
//  refusing with a `429` while CloudKit answered perfectly well is not that, so
//  each half is caught separately and the union of whatever arrived is
//  returned. Only both halves failing throws, and then the CloudKit failure is
//  the one reported — it is the one the hiker's own published hike depends on.
//
//  **A curated id must never reach CloudKit.** Every per-listing method routes
//  on ``CommunityIdentity``, and the write paths refuse a curated listing
//  outright rather than forwarding it. `takeDown(_:)` is the one that matters:
//  it builds `CKRecord.ID`s out of the listing's two names and deletes them, so
//  forwarding one would at best fail and at worst delete a record that happened
//  to be named alike.
//

import Algorithms
import CoreLocation
import Foundation
import os

/// The published hikes and the curated routes, as one list.
nonisolated struct MergedCommunityTransport: CommunityTransporting {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    let published: any CommunityTransporting
    let curated: any CuratedTrailSourcing
}

// MARK: - Browsing

extension MergedCommunityTransport {
    @concurrent
    func listings(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: Double,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        async let publishedRows = attempt {
            try await published.listings(
                near: coordinate,
                radiusMeters: radiusMeters,
                limit: limit,
                excluding: excluding
            )
        }
        let area = CommunitySearchArea(
            coordinate: coordinate,
            radiusMeters: radiusMeters
        )
        // The cheap pass only, and it runs beside CloudKit rather than after
        // it. Which of these rows are worth a line is not known until the
        // published half has answered — see ``merge(published:curated:limit:)``
        // — and a line costs 420 KB to 1.4 MB a page. Asking for geometry here
        // would be spending all of that on rows the limit then throws away.
        async let curatedListed = attemptCurated {
            try await curated.listings(near: area, limit: limit)
        }

        let publishedAnswer = await publishedRows
        let listed = await curatedListed
        let room = max(0, limit - publishedAnswer.rows.count)
        let curatedRows = room == 0 ? [] : await attemptCurated {
            try await curated.completed(Array(listed.prefix(room)))
        }

        let (rows, failure) = merge(
            published: publishedAnswer,
            curated: curatedRows,
            limit: limit
        )
        if let failure { throw failure }
        // Nearest first across both halves, so the list reads as one answer to
        // one question rather than two answers stacked. Both sources already
        // sort this way; what this settles is the interleave between them.
        return rows.sorted { lhs, rhs in
            RouteGeometry.distanceMeters(from: coordinate, to: lhs.coordinate)
                < RouteGeometry.distanceMeters(from: coordinate, to: rhs.coordinate)
        }
    }

    @concurrent
    func listings(
        matching query: String,
        limit: Int,
        excluding: Set<String>
    ) async throws -> [CommunityListing] {
        async let publishedRows = attempt {
            try await published.listings(
                matching: query,
                limit: limit,
                excluding: excluding
            )
        }
        async let curatedRows = attemptCurated {
            await curated.trails(matching: query, limit: limit)
        }
        let (rows, failure) = merge(
            published: await publishedRows,
            curated: await curatedRows,
            limit: limit
        )
        if let failure { throw failure }
        // No re-sort: there is no centre to sort by here. The published half
        // is newest first and the curated half is nearest-first within the
        // last searched area, and each stays in its own order behind the
        // other — which is also the order the limit was spent in.
        return rows
    }

    @concurrent
    func outlines(
        for listings: [CommunityListing]
    ) async throws -> [String: [RouteCoordinate]] {
        // `partitioned(by:)` answers (does not satisfy, satisfies).
        let (publishedListings, curatedListings) = listings.partitioned(by: \.isCurated)
        async let publishedOutlines: [String: [RouteCoordinate]] = publishedListings.isEmpty
            ? [:]
            : published.outlines(for: publishedListings)

        // Usually a cache read: a curated listing that came from a search
        // already has its line, because ``CuratedTrailSourcing/completed(_:)``
        // drops a route it could not draw rather than offering it. But
        // *usually* is not *always* — a long browse can evict an entry, and a
        // listing can arrive from a saved link that no search preceded — so
        // this is asked as one question about every relation at once. A loop
        // of single lookups would turn a miss into one Overpass round trip per
        // pin, at up to 30 seconds of server timeout each.
        var outlines: [String: [RouteCoordinate]] = [:]
        let relationIDs = curatedListings.compactMap { CommunityIdentity.relationID(of: $0.id) }
        let trails = (try? await curated.trails(of: relationIDs)) ?? [:]
        for listing in curatedListings {
            guard let relationID = CommunityIdentity.relationID(of: listing.id),
                  let trail = trails[relationID]
            else { continue }
            outlines[listing.id] = CommunityRouteOutline
                .simplified(trail.route)
                .map(RouteCoordinate.init)
        }

        do {
            for (id, outline) in try await publishedOutlines {
                outlines[id] = outline
            }
        } catch {
            // Partial by contract, but only where there is something to be
            // partial *about*. A request that asked about curated routes too
            // has answers in hand, and throwing would cost those as well — so
            // the published failure is logged and the caller draws what
            // arrived. A request that asked only about published hikes has
            // nothing left, and there the failure is the request's.
            guard !curatedListings.isEmpty else { throw error }
            Self.logger.error(
                """
                Published outlines unavailable, drawing \(outlines.count, privacy: .public) \
                curated lines: \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return outlines
    }

    @concurrent
    func detail(
        for listing: CommunityListing,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        guard let relationID = CommunityIdentity.relationID(of: listing.id) else {
            return try await published.detail(for: listing, downloadingInto: directory)
        }
        guard let trail = try await curated.trail(of: relationID) else {
            throw CommunityFailure.noLongerAvailable
        }
        return CommunityHikeDetail(
            listing: CommunityListing(curated: trail, editedAt: listing.publishedAt),
            route: trail.route,
            // OSM's `description` on a route relation is characteristically a
            // list of the places it passes — "Wimbachgrieshütte - Trischübel -
            // Ingolstädter Haus" — which is exactly what the hike screen's
            // *Details* row is for. Nothing is downloaded to get it; it came
            // with the tags.
            trackDescription: BoundedText.bounded(trail.tags["description"], to: .notes),
            photoPins: [],
            photoFileURLs: [],
            photosOnRecord: 0
        )
    }
}

// MARK: - Everything only a published hike has

extension MergedCommunityTransport {
    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        try await published.submit(draft)
    }

    /// Always CloudKit, and it needs no routing.
    ///
    /// The only thing ever passed here is the hiker's own
    /// ``Hike/communitySubmissionID``, which is a CloudKit record name by
    /// construction — nothing writes that column but a submission of theirs.
    @concurrent
    func publication(of submissionID: String) async throws -> CommunityListing? {
        try await published.publication(of: submissionID)
    }

    @concurrent
    func pendingSubmissions() async throws -> [CommunityPendingSubmission] {
        try await published.pendingSubmissions()
    }

    @concurrent
    func detail(
        ofPending pending: CommunityPendingSubmission,
        downloadingInto directory: URL
    ) async throws -> CommunityHikeDetail {
        try await published.detail(ofPending: pending, downloadingInto: directory)
    }

    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        of pending: CommunityPendingSubmission,
        staging: URL
    ) async throws {
        try await published.keepOnlyPhotos(kept, of: pending, staging: staging)
    }

    @concurrent
    func publish(_ pending: CommunityPendingSubmission) async throws -> CommunityListing {
        try await published.publish(pending)
    }

    @concurrent
    func decline(_ pending: CommunityPendingSubmission) async throws {
        try await published.decline(pending)
    }

    /// Refuses a curated route rather than forwarding it.
    ///
    /// The conformance below this builds `CKRecord.ID`s out of the listing's
    /// id and its submission's and deletes both. A curated route has no
    /// submission and its id is not a record name, so forwarding one is at
    /// best a failure and at worst a deletion of whatever was named alike.
    /// ``CommunityHikeView`` does not offer the action for a curated route;
    /// this is the guard behind that rather than instead of it.
    @concurrent
    func takeDown(_ listing: CommunityListing) async throws {
        guard !listing.isCurated else {
            Self.logger.error(
                "Refused to take down \(listing.id, privacy: .public): it is not a published hike."
            )
            throw CommunityFailure.notPermitted
        }
        try await published.takeDown(listing)
    }
}

// MARK: - Merging two answers

private extension MergedCommunityTransport {
    /// Runs `work`, turning a failure into one to report later.
    ///
    /// A tuple rather than a `throws`, because the whole point is that neither
    /// half may end the other: an `async let` that throws would propagate out
    /// of the `await` and take the sibling's answer with it.
    func attempt(
        _ work: () async throws -> [CommunityListing]
    ) async -> (rows: [CommunityListing], failure: CommunityFailure?) {
        do {
            return (try await work(), nil)
        } catch {
            return ([], error as? CommunityFailure ?? .unavailable(error.localizedDescription))
        }
    }

    /// The curated half, which is allowed to fail quietly.
    ///
    /// Logged rather than reported, and never the failure a merged answer
    /// throws: Overpass being busy is an ordinary condition — it answers an
    /// overloaded server with an HTML page carrying HTTP 200 — and it is not
    /// something the hiker asked about or can act on. What they asked about is
    /// the community list, and the community list still has its published
    /// half.
    func attemptCurated(
        _ work: () async throws -> [CuratedTrail]
    ) async -> [CuratedTrail] {
        do {
            return try await work()
        } catch {
            Self.logger.error(
                "Curated trails unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// The two halves as one page, with the published half served first.
    ///
    /// Returns the failure rather than throwing it so the caller decides —
    /// see the file header. A curated row is only admitted while the limit has
    /// room left after every published row has taken its place.
    ///
    /// `prefix(room)` here is belt to the caller's braces: ``listings(near:…)``
    /// already asks for lines only for the rows that fit, and this keeps the
    /// rule true for ``listings(matching:…)``, whose curated half comes out of
    /// the last search's rows rather than out of a fresh request.
    func merge(
        published: (rows: [CommunityListing], failure: CommunityFailure?),
        curated: [CuratedTrail],
        limit: Int
    ) -> (rows: [CommunityListing], failure: CommunityFailure?) {
        let room = max(0, limit - published.rows.count)
        let curatedRows = curated.prefix(room).map { trail in
            // No edit timestamp is asked for — `out meta` would double the
            // listing pass's size for a field nothing draws — so a curated
            // row's `publishedAt` is the moment it was fetched. It is never
            // shown; it exists so a merge has something defensible to order by
            // when there is no distance to use.
            CommunityListing(curated: trail, editedAt: .now)
        }
        guard !published.rows.isEmpty || !curatedRows.isEmpty else {
            // Nothing arrived from either. If CloudKit is the reason, say so;
            // an empty answer with no failure is a real answer meaning
            // "nowhere near there".
            return ([], published.failure)
        }
        return (published.rows + curatedRows, nil)
    }
}
