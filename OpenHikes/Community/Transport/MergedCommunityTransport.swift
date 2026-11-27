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
//  has to change, and the one thing above it that can tell there are two is
//  that either half may arrive early — see the fourth rule.
//
//  ## Four rules, and each of them is a correction to the obvious version
//
//  **A published hike never loses its place to a curated one.** The limit is
//  spent on CloudKit first and only the remainder is filled from Overpass. The
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
//  That used to be the end of it, and the end of it was too quiet: a curated
//  failure went to the log and nowhere else, so a hiker whose address had been
//  rate-limited saw a list with no trails in it and nothing to tell that apart
//  from an area with no trails in it. What the curated half came to is now
//  *reported beside the rows* as a ``CuratedTrailOutcome`` on the answer —
//  still never thrown, still never the request's own failure — and the *Search
//  this area* button is what draws it. That report covers the empty area as
//  well as the refusal, because those two are the pair a hiker cannot tell
//  apart from the rows alone. See ``CommunityNearbyAnswer``.
//
//  A refusal is also not the end of the curated half. What this device has
//  already downloaded near the searched area is drawn in its place — see
//  ``listCurated(near:limit:for:)`` — and the outage is reported anyway,
//  because those rows are what happens to be on the device rather than an
//  answer to the question. A search too wide for Overpass that the pre-built
//  squares could not answer ends the same way, with nothing asked of
//  Overpass: see ``CuratedTrailSearchRefusal``.
//
//  **Overpass is asked only when the question asks for it.** Every nearby
//  request used to reach both sources, which meant refilling the list after a
//  block spent two Overpass round trips nobody had asked for — against a
//  volunteer-run API with a handful of slots per address, from a list that
//  re-asks whenever the map has moved. ``CommunityNearbyScope`` is the
//  question's own answer to which sources it covers: the hiker's own
//  approaches to the trails ask for both, and the requests the app makes for
//  itself do not.
//
//  **The fast half is not held for the slow one.** CloudKit answers a nearby
//  query in a fraction of a second, and Overpass held every request it
//  admitted for 25–52 seconds when this was last measured, on 2026-10-21 —
//  once for a search of the map above the sheet, twice for a wide one; see
//  ``CuratedTrailQuery``. But the trails can be the fast half too: a search
//  over ground the hiker downloaded is answered on the device, and with no
//  signal it is CloudKit that hangs. So whichever half lands first with rows
//  to draw is handed up through `firstHalf` the moment it does, and the
//  merged answer replaces it when it arrives; only that ends the request.
//  Published rows are the ones the merged page leads with, so nothing drawn
//  early is taken away. Trails drawn early can be: the merged page still
//  spends the limit on CloudKit first, and the first rule outranks this one.
//  Only trails that came with their lines go up early, because a line still
//  to fetch costs a request that waits until the page's room is known.
//
//  **A curated id must never reach CloudKit.** Every per-listing method routes
//  on the listing's ``CommunityOrigin`` — ``CommunityListing/relationID`` and
//  ``CommunityListing/isCurated`` — and the write paths refuse a curated
//  listing outright rather than forwarding it. `takeDown(_:)` is the one that
//  matters: it builds `CKRecord.ID`s out of the listing's two names and deletes
//  them, so forwarding one would at best fail and at worst delete a record that
//  happened to be named alike.
//
//  The origin and not the id, and the two are not the same question. That a
//  listing's id begins with ``CommunityIdentity/curatedPrefix`` is a fact about
//  how the string is spelled; that it came from OpenStreetMap is a fact about
//  what it is. The two agree by construction today —
//  ``CommunityListing/init(curated:editedAt:)`` is the only thing that mints
//  the prefix and ``CommunityListing/init(record:)`` refuses a record carrying
//  it — and routing on the one that cannot come apart is what keeps a future
//  origin case from being posted to CloudKit because its id happened not to
//  match a prefix. ``CommunityIdentity/relationID(of:)`` stays for the caller
//  that genuinely holds nothing but a string: ``Hike/importedFromListingID``.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import os

/// The published hikes and the curated routes, as one list.
nonisolated struct MergedCommunityTransport: CommunityTransporting {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    let published: any CommunityTransporting
    let curated: any CuratedTrailSourcing
    /// Where a curated route's heights come from, asked once when one is
    /// on screen — see ``CuratedElevation`` and ``filledHeights(of:for:)``.
    ///
    /// Defaulted to the source that answers nothing rather than to the real
    /// one, so a caller that has not thought about it cannot reach the tile
    /// server from a suite. The composition root opts in;
    /// see ``OpenHikesModel/makeCommunityTransport()``.
    var elevation: any CuratedElevationSourcing = DormantElevationSource()
    /// Where a curated route's photographs come from, asked once when one is
    /// opened — see ``CommonsPhoto``.
    ///
    /// Defaulted to the source that answers nothing, for the reason
    /// ``elevation`` is: a caller that has not thought about it cannot reach
    /// Wikimedia from a suite. The composition root opts in.
    var commons: any CommonsPhotoSourcing = DormantCommonsPhotoSource()
}

// MARK: - Browsing

// `nonisolated` for the reason the private extension below spells it, and for
// the reason every extension of ``CloudKitCommunityTransport`` does: under
// default main-actor isolation an unannotated extension is a main-actor
// context, and what keeps these off the main actor today is `@concurrent` on
// each member individually. One helper added here without it would be a
// main-actor hop inside a transport, and nothing would say so.
nonisolated extension MergedCommunityTransport {
    @concurrent
    func listings(
        near area: CommunitySearchArea,
        limit: Int,
        excluding: Set<String>,
        scope: CommunityNearbyScope
    ) async throws -> CommunityNearbyAnswer {
        try await listings(
            near: area,
            limit: limit,
            excluding: excluding,
            scope: scope,
            firstHalf: { _ in /* the caller waits for the whole answer */ }
        )
    }

    @concurrent
    func listings(
        near area: CommunitySearchArea,
        limit: Int,
        excluding: Set<String>,
        scope: CommunityNearbyScope,
        firstHalf: @Sendable ([CommunityListing]) async -> Void
    ) async throws -> CommunityNearbyAnswer {
        // Both halves at once, with whichever lands first handed up while the
        // other is still out — see the file header's fourth rule. The trails
        // are what Overpass or the downloaded squares had to say, or — when
        // that was refused — what this device already had about the same
        // area. See ``listCurated(near:limit:for:)``.
        let (publishedAnswer, listed) = await bothHalves(
            near: area,
            limit: limit,
            excluding: excluding,
            scope: scope,
            firstHalf: firstHalf
        )
        let room = max(0, limit - publishedAnswer.rows.count)
        // Nothing to complete when the question did not ask, and nothing worth
        // completing when the published half has already spent the page. A
        // small search's rows are complete already, and completing them finds
        // every line in hand — see ``CuratedTrailSourcing/completed(_:)``.
        // The room is CloudKit's leftovers whichever half landed first, so
        // trails handed up early give their places back here.
        let curatedRows = scope == .publishedOnly || room == 0
            ? CuratedAttempt.notAsked
            : await complete(Array(listed.trails.prefix(room)))

        let (rows, failure) = merge(
            published: publishedAnswer,
            curated: curatedRows.trails,
            limit: limit
        )
        if let failure { throw failure }
        // Nearest first across both halves, so the list reads as one answer to
        // one question rather than two answers stacked. Both sources already
        // sort this way; what this settles is the interleave between them.
        return CommunityNearbyAnswer(
            listings: nearestFirst(rows, to: area.coordinate),
            curated: outcome(listed: listed, completed: curatedRows, for: scope)
        )
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
        // No outage to report from here, and none to report *about*: this
        // half is a filter over the rows the last area search already brought
        // back, so it reaches no network and cannot be rate-limited. See
        // ``CuratedTrailSourcing/trails(matching:limit:)``.
        async let curatedRows = attemptCurated {
            CuratedListing(trails: await curated.trails(matching: query, limit: limit))
        }
        let (rows, failure) = merge(
            published: await publishedRows,
            curated: await curatedRows.trails,
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

        // **Rows that have a line, and only those.** A row the geometry pass
        // was refused for has none — see ``CuratedTrailSourcing/completed(_:)``
        // — and asking about it here would put a fresh Overpass geometry
        // request straight behind the refusal that produced it, on the app's
        // own behalf and against the rule this file keeps: Overpass is asked
        // when the question asks for it. Its line arrives when the hiker opens
        // the row; until then the pin stands without one.
        //
        // What is left is usually a cache read, because a drawn row's line is
        // what drew it. But *usually* is not *always* — a long browse can evict
        // an entry, and a listing can arrive from a saved link that no search
        // preceded — so this is asked as one question about every relation at
        // once. A loop of single lookups would turn a miss into one Overpass
        // round trip per pin, at up to 30 seconds of server timeout each.
        var outlines: [String: [RouteCoordinate]] = [:]
        let drawable = curatedListings.filter { $0.drawnDistanceMeters != nil }
        let trails = (try? await curated.trails(of: drawable.compactMap(\.relationID))) ?? [:]
        for listing in drawable {
            guard let relationID = listing.relationID,
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
        guard let relationID = listing.relationID else {
            return try await published.detail(for: listing, downloadingInto: directory)
        }
        guard let trail = try await curated.trail(of: relationID) else {
            throw CommunityFailure.noLongerAvailable
        }
        // Without its heights: those are asked for once the route is on
        // screen, so neither the line nor the Add button waits on them — see
        // ``filledHeights(of:for:)``.
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

nonisolated extension MergedCommunityTransport {
    @concurrent
    func submit(_ draft: CommunitySubmissionDraft) async throws -> String {
        try await published.submit(draft)
    }

    /// Always CloudKit: a submission is one, whatever the trail it came from.
    @concurrent
    func queueForReview(submissionID: String) async throws {
        try await published.queueForReview(submissionID: submissionID)
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
    func reviewQueue() async throws -> CommunityReviewBatch {
        try await published.reviewQueue()
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

    // MARK: - Contributed photographs

    // Every one of these is CloudKit's and none of them routes, which is a
    // statement rather than an oversight. A contribution is a record in the
    // public database whichever kind of trail it is about — that is the whole
    // reason its target is a ``CommunityIdentity`` string and not a reference
    // — so OpenStreetMap has nothing to answer here. The one place the two
    // sources meet is ``detail(for:downloadingInto:)`` above, where a curated
    // route's contributed photographs are fetched from CloudKit and hung on a
    // hike Overpass described.

    @concurrent
    func submitPhotos(_ draft: CommunityPhotoDraft) async throws -> String {
        try await published.submitPhotos(draft)
    }

    @concurrent
    func queuePhotosForReview(submissionID: String) async throws {
        try await published.queuePhotosForReview(submissionID: submissionID)
    }

    @concurrent
    func contribution(of photoSubmissionID: String) async throws -> String? {
        try await published.contribution(of: photoSubmissionID)
    }

    @concurrent
    func contributedPhotos(
        for listingID: String,
        excluding: Set<String>,
        downloadingInto directory: URL
    ) async throws -> [CommunityPhotoContribution] {
        try await published.contributedPhotos(
            for: listingID,
            excluding: excluding,
            downloadingInto: directory
        )
    }

    /// Asks Commons about a curated route, and nothing about anything else.
    ///
    /// Routed on the origin, like every per-listing method here: a published
    /// hike carries the photographs its author took, and Wikimedia is not
    /// asked about a stranger's walk on the strength of where it went.
    @concurrent
    func commonsPhotos(
        for listing: CommunityListing,
        along route: [RouteCoordinate],
        downloadingInto directory: URL
    ) async throws -> [CommonsPhoto] {
        guard listing.isCurated else { return [] }
        return try await commons.photos(along: route, downloadingInto: directory)
    }

    /// The heights OpenStreetMap does not have, on a curated route already on
    /// screen, and nothing for anything else.
    ///
    /// Asked when a route is opened rather than for the list, for the reason
    /// the surface analysis is: a page offers twenty-five routes and a hiker
    /// opens one. Routed on the origin like ``commonsPhotos(for:along:downloadingInto:)``:
    /// a published hike's heights are its author's. A square that would not
    /// come, and ground with no heights, leave the route exactly as it came,
    /// which costs the chart and nothing else — see
    /// ``CuratedElevationSourcing/filled(_:)``.
    @concurrent
    func filledHeights(of route: [RouteCoordinate], for listing: CommunityListing) async -> [RouteCoordinate] {
        guard listing.isCurated else { return route }
        return await elevation.filled(route)
    }

    @concurrent
    func photos(
        ofPending pending: CommunityPendingPhotos,
        downloadingInto directory: URL
    ) async throws -> CommunityPhotoContribution {
        try await published.photos(ofPending: pending, downloadingInto: directory)
    }

    @concurrent
    func keepOnlyPhotos(
        _ kept: [CommunityKeptPhoto],
        ofPending pending: CommunityPendingPhotos,
        staging: URL
    ) async throws {
        try await published.keepOnlyPhotos(kept, ofPending: pending, staging: staging)
    }

    @concurrent
    func publishPhotos(
        _ pending: CommunityPendingPhotos
    ) async throws -> CommunityPhotoContribution {
        try await published.publishPhotos(pending)
    }

    @concurrent
    func declinePhotos(_ pending: CommunityPendingPhotos) async throws {
        try await published.declinePhotos(pending)
    }

    @concurrent
    func takeDownPhotos(_ contribution: CommunityPhotoContribution) async throws -> CommunityPhotoTakedownOutcome {
        try await published.takeDownPhotos(contribution)
    }
}

// MARK: - Merging two answers

// `nonisolated` spelled out rather than inherited. Everything here runs
// inside the `@concurrent` methods above, and the default-isolation rules
// disagree between toolchains about what a nested type in an unannotated
// extension gets: Xcode 27 reads it as nonisolated, Xcode 26.6 as main-actor,
// which fails the build with *main actor-isolated static property 'notAsked'
// cannot be accessed from outside of the actor* — and would have put the
// merge on the main actor wherever it did compile.
nonisolated private extension MergedCommunityTransport {
    /// What the CloudKit half came back with: its rows, or why there are none.
    typealias PublishedAttempt = (rows: [CommunityListing], failure: CommunityFailure?)

    /// One half of a nearby answer, as it lands — see
    /// ``bothHalves(near:limit:excluding:scope:firstHalf:)``.
    nonisolated enum Half: Sendable {
        case published(PublishedAttempt)
        case curated(CuratedAttempt)
    }

    /// Both halves of a nearby question, asked side by side, with the first to
    /// land holding rows worth drawing handed to `firstHalf` while the other is
    /// still out — see the file header's fourth rule.
    ///
    /// **At most once, and never with nothing**, for the reasons
    /// ``CommunityTransporting/listings(near:limit:excluding:scope:firstHalf:)``
    /// gives. The published rows go up whenever nothing has gone up before
    /// them, as they did when they were the only half that could. The trails go
    /// up only while CloudKit is still out — once it has answered, the merge is
    /// next — and only the ones that came with their lines; see
    /// ``drawnEarly(_:limit:)``.
    ///
    /// The curated half's first request runs beside CloudKit rather than after
    /// it. Which of its rows are worth a line is not known until the published
    /// half has answered — see ``merge(published:curated:limit:)`` — so for a
    /// wide area this is the cheap pass alone: a page of lines there is 420 KB
    /// to 1.4 MB, and asking for them here would spend all of that on rows the
    /// limit then throws away. For the map above the sheet it brings every line
    /// in the box with it, because that costs less than a second turn in
    /// Overpass's queue; the published rows still take their places first, so
    /// what the limit throws away there is bytes rather than a request. See
    /// ``CuratedTrailQuery/areaRequest(in:)``. For a
    /// ``CommunityNearbyScope/publishedOnly`` question it is not a request at
    /// all: ``listCurated(near:limit:for:)`` returns without touching the
    /// source, so the whole request is the one CloudKit query beside it.
    ///
    /// A task group rather than two `async let`s, because an `async let` is
    /// awaited in the order it is written, and which half is the slow one is
    /// exactly what is not known: over ground the hiker downloaded, with no
    /// signal, it is CloudKit that hangs while the trails are already here.
    func bothHalves(
        near area: CommunitySearchArea,
        limit: Int,
        excluding: Set<String>,
        scope: CommunityNearbyScope,
        firstHalf: @Sendable ([CommunityListing]) async -> Void
    ) async -> (published: PublishedAttempt, curated: CuratedAttempt) {
        await withTaskGroup(of: Half.self) { group in
            group.addTask { .published(await attemptPublished(near: area, limit: limit, excluding: excluding)) }
            group.addTask { .curated(await listCurated(near: area, limit: limit, for: scope)) }
            var published: PublishedAttempt = ([], nil)
            var curated = CuratedAttempt.notAsked
            var publishedLanded = false
            // A published-only question has no slower half to wait for: its
            // answer *is* the published half, and nothing goes up before it.
            var handedUp = scope == .publishedOnly
            for await half in group {
                let early: [CommunityListing]
                switch half {
                case .published(let attempt):
                    published = attempt
                    publishedLanded = true
                    early = attempt.rows
                case .curated(let attempt):
                    curated = attempt
                    early = publishedLanded ? [] : drawnEarly(attempt.trails, limit: limit)
                }
                guard !handedUp, !early.isEmpty else { continue }
                handedUp = true
                await firstHalf(nearestFirst(early, to: area.coordinate))
            }
            return (published, curated)
        }
    }

    /// The CloudKit half of a nearby question.
    ///
    /// `.publishedOnly` is what this call *is*, whatever the question was: the
    /// half being asked here is CloudKit, and the curated half of the same
    /// question is ``listCurated(near:limit:for:)``. A conformance with one
    /// source ignores the scope, and passing the caller's through would be
    /// handing a second source's instruction to a transport that has none.
    func attemptPublished(
        near area: CommunitySearchArea,
        limit: Int,
        excluding: Set<String>
    ) async -> PublishedAttempt {
        await attempt {
            try await published.listings(
                near: area,
                limit: limit,
                excluding: excluding,
                scope: .publishedOnly
            ).listings
        }
    }

    /// The trails worth drawing while CloudKit is still out: the page they
    /// would fill on their own, less any row still waiting for its line.
    ///
    /// Only rows that came with their lines, because those are rows in hand —
    /// a downloaded square's always do, and a small search's arrive with
    /// theirs — and completing them later keeps them as they came and costs no
    /// request; see ``CuratedTrailSourcing/completed(_:)``. That is also what
    /// keeps them from being followed by a thrown answer. A row without its
    /// line costs a geometry request, and which rows are worth one is not known
    /// until the published half has taken its places.
    ///
    /// The whole page rather than what would be left beside published hikes,
    /// because nobody knows yet how many of those there are. The merged answer
    /// spends the limit on CloudKit first all the same, so some of these can
    /// leave the list again when it lands — see the file header's first rule.
    func drawnEarly(_ trails: [CuratedTrail], limit: Int) -> [CommunityListing] {
        trails.prefix(max(0, limit))
            .filter { !$0.route.isEmpty }
            .map { CommunityListing(curated: $0, editedAt: .now) }
    }

    /// Runs `work`, turning a failure into one to report later.
    ///
    /// A tuple rather than a `throws`, because the whole point is that neither
    /// half may end the other: a half that threw would end the request and
    /// take the sibling's answer with it.
    ///
    /// **Logged here as well as returned**, because the returned half is not
    /// always used. ``merge(published:curated:limit:)`` reports this failure
    /// only when *both* halves came back empty; a CloudKit outage over an area
    /// where OpenStreetMap had trails is swallowed on purpose — the list the
    /// hiker gets is real and drawing *These are the hikes from the last
    /// search that worked* over it would be false. That is the right screen
    /// and it was the wrong log: the one case where the hiker's own published
    /// hike is missing from a list that looks perfectly normal left no trace
    /// anywhere at all. The curated half has said this much since it was added
    /// — see ``attemptCurated(_:)`` — and there was never a reason for the two
    /// to differ.
    ///
    /// A cancellation is not one of these. A superseded search cancels both
    /// halves mid-flight and a hiker panning across a valley supersedes
    /// several, so logging those would bury the failures worth finding under
    /// the ordinary working of the screen.
    func attempt(
        _ work: () async throws -> [CommunityListing]
    ) async -> PublishedAttempt {
        do {
            return (try await work(), nil)
        } catch {
            if !(error is CancellationError) {
                Self.logger.error(
                    "Published hikes unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
            return ([], CommunityFailure(error))
        }
    }

    /// What one pass at Overpass came back with, and why it did not.
    ///
    /// Two fields rather than a `Result` because the two are not exclusive in
    /// principle and the caller treats them separately: the rows are merged,
    /// the outage is carried out to the button that spent the request.
    nonisolated struct CuratedAttempt: Sendable {
        var trails: [CuratedTrail]
        var outage: CuratedTrailOutage?
        /// Why ``trails`` may be only part of the area's, when the listing
        /// pass answered for part of it: see ``CuratedListing/gap``.
        var gap: CuratedTrailOutage?

        /// A pass that was never made. What a
        /// ``CommunityNearbyScope/publishedOnly`` question gets, and it is not
        /// an outage: nothing was asked, so there is nothing to say.
        static let notAsked = Self(trails: [], outage: nil)
    }

    /// The listing pass, or nothing at all for a question that did not ask for
    /// one, or what is already on the device when Overpass refused.
    ///
    /// The guard is here rather than at the call site so the child task in
    /// ``bothHalves(near:limit:excluding:scope:firstHalf:)`` stays one
    /// expression, and so the rule — *Overpass is asked only when the question
    /// asks for it* — is a thing one function decides.
    ///
    /// **The fall-back keeps the outage.** It is not a recovery and must not
    /// read as one: the rows it returns are whatever this device happens to
    /// have downloaded near there, with no record of whether that is the
    /// area's trails or four of them, so the caption under *Search this area*
    /// still says the half was refused. Drawing the four is better than
    /// drawing nothing, and claiming they are the answer would be worse than
    /// either. See ``CuratedTrailStore/trails(near:limit:)``.
    ///
    /// A listing that answered for part of the area is not an outage. Its
    /// rows are that part's own, ranked as a whole answer is, and its gap
    /// goes to the caption — see ``CuratedListing/gap``. Only a part with no
    /// rows in it falls back, because there the alternative is an empty half
    /// too: the squares that were read hold no routes, and the one that was
    /// not may hold one an earlier search kept. The gap stays, for the reason
    /// the outage does.
    func listCurated(
        near area: CommunitySearchArea,
        limit: Int,
        for scope: CommunityNearbyScope
    ) async -> CuratedAttempt {
        guard scope == .withCuratedTrails else { return .notAsked }
        let attempt = await attemptCurated {
            try await curated.listings(near: area, limit: limit)
        }
        let isEmptyPart = attempt.gap != nil && attempt.trails.isEmpty
        guard attempt.outage != nil || isEmptyPart else { return attempt }
        let stored = await curated.cachedTrails(near: area, limit: limit)
        Self.logger.notice(
            """
            A curated search had no answer; drawing \(stored.count, privacy: .public) \
            trails already on this device.
            """
        )
        return CuratedAttempt(trails: stored, outage: attempt.outage, gap: attempt.gap)
    }

    /// The geometry pass, with its refusal reported rather than raised.
    ///
    /// Thinner than ``attemptCurated(_:)`` and deliberately separate from it,
    /// because the pass it wraps now reports for itself: a refused line no
    /// longer costs the row it belongs to — see
    /// ``CuratedTrailSourcing/completed(_:)`` — so ``CuratedCompletion``
    /// arrives carrying both halves and this only has to put them in the shape
    /// the merge takes.
    ///
    /// The `catch` is still load-bearing. A conformance may throw, a
    /// cancellation does, and a search superseded mid-geometry must leave as a
    /// cancellation rather than as a page of lineless rows nobody is waiting
    /// for — which is exactly what ``CuratedTrailOutage/init(_:)`` refusing a
    /// `CancellationError` arranges here.
    func complete(_ listed: [CuratedTrail]) async -> CuratedAttempt {
        let completion: CuratedCompletion
        do {
            completion = try await curated.completed(listed)
        } catch {
            let outage = CuratedTrailOutage(error)
            if outage != nil {
                Self.logger.error(
                    "Curated geometry unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
            return CuratedAttempt(trails: [], outage: outage)
        }
        if completion.outage != nil {
            let drawn = completion.trails.count { !$0.route.isEmpty }
            Self.logger.notice(
                """
                Overpass drew \(drawn, privacy: .public) lines of \
                \(listed.count, privacy: .public); the rest are offered without one.
                """
            )
        }
        return CuratedAttempt(trails: completion.trails, outage: completion.outage)
    }

    /// The curated half, which is allowed to fail without ending the request.
    ///
    /// Never the failure a merged answer throws: Overpass being busy is an
    /// ordinary condition — it answers an overloaded server with an HTML page
    /// carrying HTTP 200 — and the community list still has its published
    /// half. What changed is that it is no longer *only* logged. The reason is
    /// carried back as a ``CuratedTrailOutage`` so the control that spent the
    /// request can say the trails are missing, which is the difference between
    /// an area with no waymarked routes in it and an address that has been
    /// asked to stop for a minute.
    ///
    /// The log follows the outage rather than the `catch`, so the one error
    /// ``CuratedTrailOutage/init(_:)`` refuses is the one error this stays
    /// quiet about: a cancellation is a superseded search, not a service that
    /// would not answer.
    func attemptCurated(
        _ work: () async throws -> CuratedListing
    ) async -> CuratedAttempt {
        do {
            let listing = try await work()
            return CuratedAttempt(trails: listing.trails, outage: nil, gap: listing.gap)
        } catch {
            let outage = CuratedTrailOutage(error)
            if outage != nil {
                Self.logger.error(
                    "Curated trails unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
            return CuratedAttempt(trails: [], outage: outage)
        }
    }

    /// What to report about the OpenStreetMap half of an answer: nothing, a
    /// count, a refusal, or a part.
    ///
    /// The listing pass's outage comes first because it is the pass that
    /// decides whether there was anything to complete, so its refusal is the
    /// one that explains an answer with no trails in it. A gap comes after
    /// the outages: rows that were answered for, beside a gap, are no count
    /// of the area's trails, an empty page least of all. The count is that
    /// same pass's, for the reason ``CuratedTrailOutcome/trails(_:)`` gives:
    /// it is what OpenStreetMap had near the area, which is the question the
    /// caption under *Search this area* answers, while the rows are what the
    /// page had room for.
    ///
    /// The scope is asked about rather than inferred from an empty attempt,
    /// because ``CuratedAttempt/notAsked`` and a genuinely empty area are the
    /// same two fields and must not become the same sentence.
    func outcome(
        listed: CuratedAttempt,
        completed: CuratedAttempt,
        for scope: CommunityNearbyScope
    ) -> CuratedTrailOutcome {
        guard scope == .withCuratedTrails else { return .notAsked }
        if let outage = listed.outage ?? completed.outage { return .outage(outage) }
        if let gap = listed.gap { return .partial(gap) }
        return .trails(listed.trails.count)
    }

    /// `rows` nearest `coordinate` first.
    ///
    /// Measured once per row and then sorted, rather than measured inside the
    /// comparator: a haversine is trigonometry, and a comparator that
    /// recomputes both sides runs it twice per comparison — about two hundred
    /// times for a page, against fifty here. See
    /// ``CuratedTrailSource/listings(near:limit:)``, which sorts the same way
    /// over four times as many rows.
    func nearestFirst(
        _ rows: [CommunityListing],
        to coordinate: CLLocationCoordinate2D
    ) -> [CommunityListing] {
        rows
            .map { ($0, RouteGeometry.distanceMeters(from: coordinate, to: $0.coordinate)) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
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
        published: PublishedAttempt,
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
