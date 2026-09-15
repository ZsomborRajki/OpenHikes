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

import CoreLocation
import Foundation
import os

/// Where the community list's curated hikes come from.
///
/// A protocol for the same reason ``CommunityTransporting`` is one: the
/// conformance below reaches a volunteer-run public API, and no suite may.
nonisolated protocol CuratedTrailSourcing: Sendable {
    /// Waymarked day hikes near `area`, nearest first, with their lines.
    ///
    /// Answers `[]` rather than throwing for an area too wide to ask about —
    /// see ``CuratedTrailQuery/maximumRadiusMeters``. That is an answer: the
    /// hiker is looking at half a continent, where a list of village loops is
    /// not what they asked for.
    @concurrent
    func trails(near area: CommunitySearchArea, limit: Int) async throws -> [CuratedTrail]

    /// Curated hikes from the last searched area whose name matches `query`.
    ///
    /// Deliberately local, and deliberately not a request. Overpass has no
    /// index to search the world by name — every query is bounded by an area —
    /// so a global title search is not a question this source can be asked.
    /// What it *can* answer is the one the hiker is actually asking while
    /// looking at a map: which of the trails around here is called this. That
    /// needs no round trip at all, because the rows are already in hand.
    @concurrent
    func trails(matching query: String, limit: Int) async -> [CuratedTrail]

    /// One route, complete, from the cache or from Overpass.
    ///
    /// Answers `nil` for a relation that is gone or too fragmented to draw —
    /// see ``CuratedTrailDecoding/minimumConnectedShare``. An OSM relation id
    /// is stable but not permanent: routes are split, merged and deleted, so a
    /// hike saved from a link last month can simply not be there.
    @concurrent
    func trail(of relationID: Int64) async throws -> CuratedTrail?
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

    private let endpoint: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date

    /// Complete routes by relation id, with an insertion order so the oldest
    /// goes first.
    private var cachedTrails: [Int64: CuratedTrail] = [:]
    private var trailOrder: [Int64] = []

    /// What the last area search answered, for ``trails(matching:limit:)``.
    private var lastAnswer: [CuratedTrail] = []

    /// When Overpass will accept another request, if it has told us to wait.
    ///
    /// The same courtesy ``OverpassTrailGraphProvider`` extends: a `429` is a
    /// request to stop asking, and retrying into it is what turns one rate
    /// limit into a block.
    private var retryAfter: Date?

    init(
        endpoint: URL = URL(string: "https://overpass-api.de/api/interpreter")!,
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
}

// MARK: - Searching

extension CuratedTrailSource {
    func trails(near area: CommunitySearchArea, limit: Int) async throws -> [CuratedTrail] {
        guard limit > 0, let box = CuratedTrailQuery.boundingBox(for: area) else {
            return []
        }
        try checkRateLimit()

        let body = try await send(CuratedTrailQuery.listingQuery(in: box))
        let listed = try CuratedTrailDecoding.trails(fromListing: body)
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

        let answer = try await completed(Array(nearest))
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

    func trail(of relationID: Int64) async throws -> CuratedTrail? {
        if let cached = cachedTrails[relationID] { return cached }
        try checkRateLimit()
        guard let query = CuratedTrailQuery.geometryQuery(ids: [relationID]) else {
            return nil
        }
        let decoded = try CuratedTrailDecoding.trails(
            fromGeometry: try await send(query)
        )
        for (id, trail) in decoded { cache(trail, for: id) }
        return decoded[relationID]
    }
}

// MARK: - The geometry pass

private extension CuratedTrailSource {
    /// Fills in each listed route's line, dropping the ones that have none.
    ///
    /// A route with no line is left out rather than shown without one, and
    /// that is a stricter rule than the published half follows — there, a
    /// missing outline costs a line and leaves the pin standing, because the
    /// hike itself is still openable and still has a distance of its own. A
    /// curated route has neither: its length *is* the line's length, so a row
    /// without one would be a name and a blank. See
    /// ``CuratedTrailDecoding/minimumConnectedShare`` for the other reason a
    /// line is absent — a relation too fragmented to draw as one walk.
    ///
    /// The listing order is preserved rather than the geometry response's,
    /// which arrives in whatever order Overpass assembled it. That order is
    /// *nearest first*, and it is the whole answer to the question the hiker
    /// asked.
    func completed(_ listed: [CuratedTrail]) async throws -> [CuratedTrail] {
        let missing = listed.map(\.relationID).filter { cachedTrails[$0] == nil }
        if let query = CuratedTrailQuery.geometryQuery(ids: missing) {
            let body = try await send(query)
            for (id, trail) in try CuratedTrailDecoding.trails(fromGeometry: body) {
                cache(trail, for: id)
            }
        }
        return listed.compactMap { cachedTrails[$0.relationID] }
    }

    func cache(_ trail: CuratedTrail, for relationID: Int64) {
        if cachedTrails.updateValue(trail, forKey: relationID) == nil {
            trailOrder.append(relationID)
        }
        while trailOrder.count > Self.maximumCachedTrails {
            cachedTrails.removeValue(forKey: trailOrder.removeFirst())
        }
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
