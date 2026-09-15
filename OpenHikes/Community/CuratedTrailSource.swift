//
//  CuratedTrailSource.swift
//  OpenHikes
//
//  Where the curated hikes come from: two Overpass passes, and a memory of
//  what the last one answered.
//
//  An actor for the reason ``OverpassTrailGraphProvider`` is one — it owns
//  mutable state that arrives from concurrent requests — and it carries the
//  same three seams for the reason that one does: an injectable transport, an
//  injectable clock, and nothing static. See *Deliberate test seams* in the
//  repository instructions. A suite must be able to drive every branch here
//  without a network, and the rate-limit back-off is only observable against a
//  clock somebody else is holding.
//
//  ## Why the cache is in memory and keyed by relation
//
//  ``OverpassTrailGraphProvider``'s z12-tile files on disk are the right shape
//  for its question and the wrong shape for this one, and the difference is
//  two orders of magnitude. A z12 tile is 6.9 km across at 47°N; a community
//  search is 10–40 km of *radius*, so the smallest search this feature allows
//  already spans about 25 tiles and the largest about 400 — against a cache
//  that holds 64 files and a prefetch ceiling of 24 regions. One pan would
//  evict the lot.
//
//  So the unit here is the **relation**, which is what is actually re-asked
//  for: panning back to an area, or opening a hike whose line the list
//  already fetched. Those are hits, and they are the two that happen. The
//  cache does not survive a launch, which is the honest bargain — OSM data
//  changes under it, a browse session is minutes long, and the alternative is
//  a second on-disk cache to keep coherent for a gain nobody measured.
//

import Algorithms
import CoreLocation
import Foundation
import os

/// Where the community list's curated hikes come from.
///
/// A protocol for the same reason ``CommunityTransporting`` is one: the
/// conformance below reaches a volunteer-run public API, and no suite may.
nonisolated protocol CuratedTrailSourcing: Sendable {
    /// Waymarked day hikes near `area`, nearest first and **without their
    /// lines**.
    ///
    /// The cheap half of a search, split from the expensive half on purpose.
    /// A caller cannot know how many curated rows it has room for until the
    /// published half has answered — see ``MergedCommunityTransport``, where
    /// the limit is spent on CloudKit first — and geometry fetched for a row
    /// that is then discarded is the single most expensive mistake this
    /// feature can make: 420 KB to 1.4 MB per page, per search. So the rows
    /// arrive first and ``completed(_:)`` is asked only about the ones that
    /// fit.
    ///
    /// Answers `[]` rather than throwing for an area too wide to ask about —
    /// see ``CuratedTrailQuery/maximumRadiusMeters``. That is an answer: the
    /// hiker is looking at half a continent, where a list of village loops is
    /// not what they asked for.
    @concurrent
    func listings(near area: CommunitySearchArea, limit: Int) async throws -> [CuratedTrail]

    /// The routes in `listed` with their lines filled in, dropping the ones
    /// that have none.
    ///
    /// **Partial by contract**, and the listing order is preserved: it is
    /// nearest first, which is the whole answer to the question the hiker
    /// asked. A route whose ways could not be assembled into one walkable line
    /// is absent rather than present as a name with a blank where its distance
    /// should be — see ``CuratedTrailDecoding/minimumConnectedShare``.
    ///
    /// This is also what ``trails(matching:limit:)`` later searches, because
    /// these are the rows that were actually offered.
    @concurrent
    func completed(_ listed: [CuratedTrail]) async throws -> [CuratedTrail]

    /// Curated hikes from the last searched area whose name matches `query`.
    ///
    /// Deliberately local, and deliberately not a request. Overpass has no
    /// index to search the world by name — every query is bounded by an area —
    /// so a global title search is not a question this source can be asked.
    /// What it *can* answer is the one the hiker is actually asking while
    /// looking at a map: which of the trails around here is called this. That
    /// needs no round trip at all, because the rows are already in hand.
    ///
    /// *The last searched area* is meant strictly: an area whose search failed
    /// or was never completed has no rows here, so a hiker who has panned to
    /// Scotland is never offered the Alps.
    @concurrent
    func trails(matching query: String, limit: Int) async -> [CuratedTrail]

    /// Several routes, complete, from the cache or from Overpass.
    ///
    /// Plural because the callers are plural — a map full of curated pins asks
    /// about every line at once — and one request for twenty-five relations is
    /// what the geometry pass is shaped for. Absent from the answer for a
    /// relation that is gone or too fragmented to draw; an OSM relation id is
    /// stable but not permanent, so routes are split, merged and deleted.
    @concurrent
    func trails(of relationIDs: [Int64]) async throws -> [Int64: CuratedTrail]
}

nonisolated extension CuratedTrailSourcing {
    /// One route, complete, from the cache or from Overpass.
    ///
    /// `nil` for a relation that is gone or too fragmented to draw. Spelled
    /// once here rather than by every conformance, because it is
    /// ``trails(of:)`` asked about one thing.
    @concurrent
    func trail(of relationID: Int64) async throws -> CuratedTrail? {
        try await trails(of: [relationID])[relationID]
    }
}

/// Curated hikes from the public Overpass API.
actor CuratedTrailSource: CuratedTrailSourcing {
    typealias Transport = @Sendable (URLRequest) async throws -> OverpassHTTPResponse

    private static let logger = Logger(subsystem: "OpenHikes", category: "Community")

    /// How many routes are kept in memory.
    ///
    /// Four pages of results. Enough that panning back and forth across two or
    /// three areas is free, small enough that a long browse cannot grow
    /// without bound — a line is a few hundred points, so this is on the order
    /// of a megabyte at its fullest.
    private static let maximumCachedTrails = 100

    /// What the cache knows about one relation.
    ///
    /// Absence is a cached answer rather than a missing one, because it is an
    /// answer Overpass gave and it does not change while the app is running:
    /// a relation that is gone is gone, and one too fragmented to assemble is
    /// too fragmented every time. Without this, the *Try Again* on a hike that
    /// can no longer be drawn re-runs the whole geometry pass on every tap.
    private enum CachedTrail {
        case trail(CuratedTrail)
        /// Asked about, and Overpass had nothing to draw.
        case absent

        var trail: CuratedTrail? {
            switch self {
            case .trail(let trail): trail
            case .absent: nil
            }
        }
    }

    private let endpoint: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date

    /// What is known about each relation, with an eviction order whose oldest
    /// end is the **least recently used** rather than the first inserted.
    ///
    /// Least recently used and not first inserted, because the two differ
    /// exactly where it matters. A search that lists twenty-five routes of
    /// which five are cached and twenty are not caches the twenty, evicts the
    /// twenty oldest — which under insertion order includes those five, the
    /// ones being looked at right now — and the search answers with twenty
    /// rows where it listed twenty-five, saying nothing about the five it
    /// dropped. Touching an entry on every read is what keeps the rows a
    /// hiker is looking at out of the eviction window.
    private var cachedTrails: [Int64: CachedTrail] = [:]
    private var trailOrder: [Int64] = []

    /// What the last area search answered, for ``trails(matching:limit:)``.
    private var lastAnswer: [CuratedTrail] = []

    /// The area ``lastAnswer`` describes.
    ///
    /// Held so a stale answer can be recognised as one. Without it a search
    /// whose Overpass half failed — a `429`, or an area past
    /// ``CuratedTrailQuery/maximumRadiusMeters`` — leaves the *previous*
    /// area's routes standing, and the hiker who has panned from Berchtesgaden
    /// to Scotland and typed a name gets Alpine trails pinned hundreds of
    /// kilometres off the map they are looking at.
    private var lastArea: CommunitySearchArea?

    /// When Overpass will accept another request, if it has told us to wait.
    ///
    /// The same courtesy ``OverpassTrailGraphProvider`` extends: a `429` is a
    /// request to stop asking, and retrying into it is what turns one rate
    /// limit into a block.
    private var retryAfter: Date?

    init(
        endpoint: URL = OverpassRequest.defaultEndpoint,
        clock: @escaping @Sendable () -> Date = { Date() },
        transport: Transport? = nil
    ) {
        self.endpoint = endpoint
        self.clock = clock
        self.transport = transport ?? { request in
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw TrailGraphProviderError.invalidResponse
            }
            return OverpassHTTPResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                headers: OverpassRequest.headers(of: httpResponse)
            )
        }
    }

    // MARK: - The cache

    private func cache(_ cached: CachedTrail, for relationID: Int64) {
        if cachedTrails.updateValue(cached, forKey: relationID) == nil {
            trailOrder.append(relationID)
        } else {
            touch(relationID)
        }
        while trailOrder.count > Self.maximumCachedTrails {
            cachedTrails.removeValue(forKey: trailOrder.removeFirst())
        }
    }

    /// Moves `relationID` to the newest end of the eviction order.
    ///
    /// A linear scan of a hundred ids, on a path that is already a network
    /// decision — a linked list to make it constant would be more moving parts
    /// than the thing it speeds up.
    private func touch(_ relationID: Int64) {
        guard let index = trailOrder.firstIndex(of: relationID) else { return }
        trailOrder.append(trailOrder.remove(at: index))
    }

    /// Drops the memory of what the last area search answered.
    ///
    /// The cache is untouched: those routes are still true, and re-listing
    /// them should still be free. What is thrown away is only the claim that
    /// they describe *around here*.
    private func forgetLastAnswer() {
        lastAnswer = []
        lastArea = nil
    }
}

// MARK: - Searching

extension CuratedTrailSource {
    func listings(near area: CommunitySearchArea, limit: Int) async throws -> [CuratedTrail] {
        // Cleared before anything that can fail, so every path out of here
        // except a completed search leaves nothing behind for
        // ``trails(matching:limit:)`` to answer a different area with. The
        // same area asked twice keeps its rows: that is a refresh, not a move.
        if lastArea != area { forgetLastAnswer() }
        let boxes = CuratedTrailQuery.searchBoxes(for: area)
        guard limit > 0,
              let query = CuratedTrailQuery.listingQuery(in: boxes)
        else {
            forgetLastAnswer()
            return []
        }
        try checkRateLimit()

        let listed = try CuratedTrailDecoding.trails(fromListing: try await send(query))
        // Nearest first, by the same measure the published half is sorted by,
        // so a merged list is ordered by one rule rather than by two that
        // happen to agree near the centre.
        let centre = area.coordinate
        let nearest = listed
            .sorted { lhs, rhs in
                RouteGeometry.distanceMeters(from: centre, to: lhs.coordinate)
                    < RouteGeometry.distanceMeters(from: centre, to: rhs.coordinate)
            }
            .prefix(min(limit, CuratedTrailQuery.geometryBatchLimit))
        lastArea = area
        return Array(nearest)
    }

    /// Fills in each listed route's line, dropping the ones that have none.
    ///
    /// A route with no line is left out rather than shown without one, and
    /// that is a stricter rule than the published half follows — there, a
    /// missing outline costs a line and leaves the pin standing, because the
    /// hike itself is still openable and still has a distance of its own. A
    /// curated route has neither: its length *is* the line's length, so a row
    /// without one would be a name and a blank.
    ///
    /// What comes back is what ``trails(matching:limit:)`` then searches,
    /// because these are the rows that were offered — a route the search had
    /// no room to draw is not one the hiker can be shown a distance for.
    func completed(_ listed: [CuratedTrail]) async throws -> [CuratedTrail] {
        let known = try await trails(of: listed.map(\.relationID))
        // Built from what the fetch answered rather than read back out of the
        // cache, so eviction during this very call cannot quietly shorten the
        // list the hiker is looking at.
        let answer = listed.compactMap { known[$0.relationID] }
        lastAnswer = answer
        return answer
    }

    func trails(matching query: String, limit: Int) -> [CuratedTrail] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !needle.isEmpty, limit > 0 else { return [] }
        return Array(
            lastAnswer
                .filter { $0.name.localizedLowercase.contains(needle) }
                .prefix(limit)
        )
    }

    func trails(of relationIDs: [Int64]) async throws -> [Int64: CuratedTrail] {
        var answer: [Int64: CuratedTrail] = [:]
        var missing: [Int64] = []
        for relationID in relationIDs.uniqued() {
            switch cachedTrails[relationID] {
            case .trail(let trail):
                answer[relationID] = trail
                touch(relationID)
            case .absent:
                touch(relationID)
            case nil:
                missing.append(relationID)
            }
        }
        guard !missing.isEmpty else { return answer }
        try checkRateLimit()

        // Chunked because ``CuratedTrailQuery/geometryQuery(ids:)`` answers
        // about at most a batch at a time and drops the rest silently, and a
        // map can hold more curated pins than one batch holds routes.
        for chunk in missing.chunks(ofCount: CuratedTrailQuery.geometryBatchLimit) {
            guard let query = CuratedTrailQuery.geometryQuery(ids: Array(chunk)) else { continue }
            let decoded = try CuratedTrailDecoding.trails(fromGeometry: try await send(query))
            for relationID in chunk {
                // An id the response did not carry is one Overpass has nothing
                // to draw for — deleted, or too fragmented to assemble. That is
                // an answer, and it is cached as one.
                guard let trail = decoded[relationID] else {
                    cache(.absent, for: relationID)
                    continue
                }
                answer[relationID] = trail
                cache(.trail(trail), for: relationID)
            }
        }
        return answer
    }
}

// MARK: - Talking to Overpass

private extension CuratedTrailSource {
    /// Throws while a `429`'s `Retry-After` is still running.
    ///
    /// Checked before a request rather than after, so a rate-limited browse
    /// costs nothing at all rather than one refused round trip per search.
    func checkRateLimit() throws {
        guard let retryAfter, retryAfter > clock() else { return }
        throw TrailGraphProviderError.rateLimited(
            retryAfter: retryAfter.timeIntervalSince(clock())
        )
    }

    func send(_ query: String) async throws -> Data {
        try Task.checkCancellation()
        let response = try await transport(OverpassRequest.post(query, to: endpoint))
        do {
            return try OverpassRequest.body(of: response)
        } catch let error as TrailGraphProviderError {
            if case .rateLimited(let delay) = error {
                // `max` rather than assignment: two requests can be refused at
                // once, and the later deadline is the one that holds.
                let candidate = clock().addingTimeInterval(delay)
                retryAfter = max(retryAfter ?? .distantPast, candidate)
                Self.logger.error(
                    "Overpass rate-limited a curated search for \(delay, privacy: .public)s."
                )
            }
            throw error
        }
    }
}
