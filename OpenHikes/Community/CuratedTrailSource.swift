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
//  ## Why the cache is keyed by relation, and why there are two of them
//
//  ``OverpassTrailGraphProvider``'s z12-tile files are the right shape for its
//  question and the wrong shape for this one, and the difference is two orders
//  of magnitude. A z12 tile is 6.9 km across at 47°N; a community search is
//  10–40 km of *radius*, so the smallest search this feature allows already
//  spans about 25 tiles and the largest about 400 — against a cache that holds
//  64 files. One pan would evict the lot.
//
//  So the unit here is the **relation**, which is what is actually re-asked
//  for: panning back to an area, or opening a hike whose line the list already
//  fetched. Those are hits, and they are the two that happen.
//
//  The memory cache below is the first of the two, and it answers within a
//  session. ``CuratedTrailStore`` is the second and answers across launches —
//  see that file for why the bargain changed, which is that a miss against a
//  volunteer-run API is priced in `429`s rather than in round trips. Reads go
//  memory, then disk, then Overpass; a fetch writes both. The memory one stays
//  because it is what keeps a browse from touching the file system on every
//  pin, and because it is the only one that can hold ``CachedTrail/absent``.
//

import Algorithms
import CoreLocation
import Foundation
import OrderedCollections
import os

/// What a geometry pass came back with.
///
/// A type rather than an array because *a line is missing* has two meanings
/// and only one of them is a reason to drop the row — see
/// ``CuratedTrailSourcing/completed(_:)``. The rows and the refusal travel
/// together for the reason ``CommunityNearbyAnswer``'s two fields do: a caller
/// that reads only the first draws exactly what it drew before, and the
/// caption under *Search this area* is the second one's whole audience.
nonisolated struct CuratedCompletion: Equatable, Sendable {
    /// The listed routes in listing order — drawn where a line arrived, and
    /// lineless where one was refused.
    var trails: [CuratedTrail]
    /// Why a line is missing, when the reason is a refusal rather than a route
    /// with nothing to draw. `nil` when every line that could be drawn was.
    var outage: CuratedTrailOutage?

    init(trails: [CuratedTrail], outage: CuratedTrailOutage? = nil) {
        self.trails = trails
        self.outage = outage
    }
}

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

    /// The routes in `listed` with their lines filled in, and what happened to
    /// the ones without.
    ///
    /// **Partial by contract**, and the listing order is preserved: it is
    /// nearest first, which is the whole answer to the question the hiker
    /// asked.
    ///
    /// A line can be missing for two reasons and they are not the same thing,
    /// which is what ``CuratedCompletion`` exists to say. A route whose ways
    /// could not be assembled into one walkable line — deleted, or too
    /// fragmented to draw — is *absent*, permanently, rather than present as a
    /// name with a blank where its distance should be; see
    /// ``CuratedTrailDecoding/minimumConnectedShare``. A route whose line was
    /// **refused** is a different case: this minute's weather on a
    /// volunteer-run API, about a row the listing pass already paid for. That
    /// one is kept, without its line, and the refusal is reported beside it.
    ///
    /// This is also what ``trails(matching:limit:)`` later searches, because
    /// these are the rows that were actually offered.
    @concurrent
    func completed(_ listed: [CuratedTrail]) async throws -> CuratedCompletion

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

    /// Routes already on this device whose pin stands in `area`, nearest
    /// first, asking nothing of Overpass.
    ///
    /// **What a refused search draws instead of nothing.** It makes no claim
    /// to be the area's trails — nothing records which areas have been listed
    /// — so it is only ever used where the alternative is an empty half and
    /// the hiker has already been told the half is degraded: see
    /// ``MergedCommunityTransport`` and ``CuratedTrailOutage``.
    ///
    /// Never throws. A cache with nothing in it is an answer, and this is
    /// reached on a path where something has already failed.
    @concurrent
    func cachedTrails(near area: CommunitySearchArea, limit: Int) async -> [CuratedTrail]
}

nonisolated extension CuratedTrailSourcing {
    /// Nothing, for a source that keeps nothing.
    ///
    /// A default rather than a requirement every conformance restates: the
    /// stand-ins a suite or a UI scenario runs against reach no network, so
    /// there is nothing for them to have failed to reach and nothing for them
    /// to fall back to.
    @concurrent
    func cachedTrails(near area: CommunitySearchArea, limit: Int) async -> [CuratedTrail] {
        []
    }

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
    }

    private let endpoint: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date
    /// The routes this device already has, across launches. `nil` for a launch
    /// with nowhere to put them — a directory that cannot be created is a
    /// cache that is simply absent, which costs round trips and breaks
    /// nothing.
    private let store: CuratedTrailStore?

    /// What is known about each relation *this session*, with an eviction
    /// order whose oldest end is the **least recently used** rather than the
    /// first inserted.
    ///
    /// In front of ``store``, not instead of it: an eviction here costs a file
    /// read rather than a round trip.
    ///
    /// Least recently used and not first inserted, because the two differ
    /// exactly where it matters. A search that lists twenty-five routes of
    /// which five are cached and twenty are not caches the twenty, evicts the
    /// twenty oldest — which under insertion order includes those five, the
    /// ones being looked at right now — and the search answers with twenty
    /// rows where it listed twenty-five, saying nothing about the five it
    /// dropped. Touching an entry on every read is what keeps the rows a
    /// hiker is looking at out of the eviction window.
    ///
    /// One ``OrderedDictionary`` rather than a dictionary beside an array of
    /// keys, which is what this was and which is two structures that can
    /// disagree — a `removeValue` without its matching `remove(at:)` leaves
    /// the order naming a relation the cache no longer holds. The order *is*
    /// the storage here: the oldest end is `first`, ``touch(_:)`` is a move to
    /// the back rather than a linear scan, and eviction is `removeFirst()`.
    /// ``WeatherRequestState`` keeps its own recency list exactly this way.
    private var cachedTrails: OrderedDictionary<Int64, CachedTrail> = [:]

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

    /// - Parameter directory: Where downloaded routes are kept between
    ///   launches. A suite passes one of its own — see *Deliberate test seams*
    ///   in the repository instructions — and must, since the default is the
    ///   app's own `Caches`.
    init(
        endpoint: URL = OverpassRequest.defaultEndpoint,
        directory: URL? = CuratedTrailStore.defaultDirectory(),
        clock: @escaping @Sendable () -> Date = { Date() },
        transport: Transport? = nil
    ) {
        self.endpoint = endpoint
        self.clock = clock
        store = directory.map { CuratedTrailStore(directory: $0, clock: clock) }
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

    /// Writes `cached` down and marks it the most recently used, evicting the
    /// least recent ones if that puts the cache over its limit.
    ///
    /// Two separate things, said separately: the value is written where it
    /// sits, and *then* moved to the back. A key not seen before is appended
    /// by the subscript, so the move that follows finds it already last and
    /// does nothing.
    private func cache(_ cached: CachedTrail, for relationID: Int64) {
        cachedTrails[relationID] = cached
        touch(relationID)
        while cachedTrails.count > Self.maximumCachedTrails {
            cachedTrails.removeFirst()
        }
    }

    /// Moves `relationID` to the newest end of the eviction order.
    ///
    /// Silent about a relation the cache does not hold, because the callers
    /// are reads: ``trails(of:)`` touches what it found, and there is nothing
    /// to reorder for what it did not.
    private func touch(_ relationID: Int64) {
        guard cachedTrails[relationID] != nil else { return }
        cachedTrails.move(keys: CollectionOfOne(relationID), to: cachedTrails.count)
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
        //
        // Measured once per relation and then ordered, rather than measured
        // inside a comparator: a full sort with a haversine on both sides runs
        // the trigonometry about fourteen hundred times over the hundred-odd
        // relations one Alpine box answers with, to keep twenty-five of them.
        // `min(count:)` is the shape ``CuratedTrailStore/trim()`` already uses
        // for the same question — *the k smallest, in order* — and it is what
        // `sorted().prefix()` was spelling the long way.
        let centre = area.coordinate
        let nearest = listed
            .map { (trail: $0, distance: RouteGeometry.distanceMeters(from: centre, to: $0.coordinate)) }
            .min(count: min(limit, CuratedTrailQuery.geometryBatchLimit)) { $0.distance < $1.distance }
            .map(\.trail)
        lastArea = area
        return nearest
    }

    /// Fills in each listed route's line, keeping a row whose line was refused
    /// and dropping one that has none to draw.
    ///
    /// **The two are not the same thing, and a search used to lose both.** A
    /// route that cannot be assembled into one walkable line has nothing to
    /// offer a hiker: its length *is* its line's length, so the row would be a
    /// name and a blank for ever, and it stays out. A route whose geometry
    /// pass was *refused* is a row the listing pass already paid a slot for,
    /// about a trail that is really there — Overpass allows a handful of slots
    /// per address and one search spends two of them, so a refusal on the
    /// second is an ordinary afternoon rather than an exotic one. Throwing
    /// that page away meant a hiker who had just spent a search got an empty
    /// list; keeping it means they get the names, the pins and what the
    /// signpost says, and the line arrives when they open one — see
    /// ``MergedCommunityTransport/detail(for:downloadingInto:)``, which
    /// fetches the geometry of the one route being opened.
    ///
    /// What comes back is what ``trails(matching:limit:)`` then searches,
    /// lineless rows included: they were offered, so they are findable.
    func completed(_ listed: [CuratedTrail]) async throws -> CuratedCompletion {
        let gathered = await gather(listed.map(\.relationID))
        // A superseded search is not an outage and must not be reported as
        // one — see ``CuratedTrailOutage/init(_:)``. It is also not an answer,
        // so it leaves the way it arrived rather than as a page of lineless
        // rows nobody is waiting for.
        if let refusal = gathered.refusal, refusal is CancellationError { throw refusal }
        // Built from what the fetch answered rather than read back out of the
        // cache, so eviction during this very call cannot quietly shorten the
        // list the hiker is looking at.
        let answer = listed.compactMap { trail -> CuratedTrail? in
            if let drawn = gathered.found[trail.relationID] { return drawn }
            // No line, so which of the two is it? A relation Overpass has
            // already said it has nothing to draw for is the permanent one and
            // stays out even here — the refusal is about the rest of the page,
            // not about this route, and a row that could never be drawn is no
            // better for being kept.
            guard gathered.refusal != nil, !isKnownAbsent(trail.relationID) else { return nil }
            return trail
        }
        lastAnswer = answer
        return CuratedCompletion(
            trails: answer,
            outage: gathered.refusal.flatMap(CuratedTrailOutage.init)
        )
    }

    /// Whether the cache holds *Overpass has nothing to draw for this* about
    /// `relationID`.
    ///
    /// Only the in-memory cache can hold that answer — see ``CachedTrail`` —
    /// so this is a miss for a relation nobody has asked about this session,
    /// which is the right answer: unknown is not the same as undrawable, and
    /// only the latter keeps a row off the list.
    private func isKnownAbsent(_ relationID: Int64) -> Bool {
        if case .absent = cachedTrails[relationID] { return true }
        return false
    }

    /// `@concurrent` rather than actor-isolated like everything around it, and
    /// for two reasons that agree. It reads every file in the cache directory,
    /// which is not work to do on the executor a search is waiting on — and it
    /// is what the requirement asks for, so an actor-isolated version would be
    /// witnessed by the protocol extension's `[]` instead and this would
    /// quietly never run. It touches no mutable state: ``store`` is a `let`.
    @concurrent
    func cachedTrails(near area: CommunitySearchArea, limit: Int) async -> [CuratedTrail] {
        store?.trails(near: area, limit: limit) ?? []
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
        let gathered = await gather(relationIDs)
        // Partial rather than nothing, when there is something to be partial
        // with. A geometry pass refused after the listing pass got through
        // would otherwise throw away every line this device already had — and
        // this is partial by contract, so a short answer is one its callers
        // already know how to draw. Only an answer with nothing in it at all
        // has the refusal as its whole content.
        if let refusal = gathered.refusal, gathered.found.isEmpty { throw refusal }
        return gathered.found
    }

    /// Every route of `relationIDs` this device or Overpass can produce, and
    /// the refusal that stopped the rest.
    ///
    /// Split from ``trails(of:)`` because the two callers need different
    /// halves of the same work and one of them cannot be told by a `throw`.
    /// `trails(of:)` answers *the lines*, and a refusal it can be partial
    /// about is one it swallows; ``completed(_:)`` answers *the rows*, and
    /// there the difference between a line that is missing because Overpass
    /// refused and one missing because there is nothing to draw decides
    /// whether the hiker sees the row at all. A swallowed refusal took that
    /// decision away from it, and the page went with it.
    ///
    /// Never throws, cancellation included: a cancelled fetch is carried out
    /// as the refusal, and the callers decide what it means to them.
    private func gather(
        _ relationIDs: [Int64]
    ) async -> (found: [Int64: CuratedTrail], refusal: (any Error)?) {
        var found: [Int64: CuratedTrail] = [:]
        var missing: [Int64] = []
        for relationID in relationIDs.uniqued() {
            switch cachedTrails[relationID] {
            case .trail(let trail):
                found[relationID] = trail
                touch(relationID)
            case .absent:
                touch(relationID)
            case nil:
                // Disk before the network, and promoted into memory on the way
                // past so a map full of pins reads each file once. A stored
                // route is not re-stated as `.absent` when it is missing —
                // that is what the request below is for.
                guard let stored = store?.trail(of: relationID) else {
                    missing.append(relationID)
                    continue
                }
                found[relationID] = stored
                cache(.trail(stored), for: relationID)
            }
        }
        guard !missing.isEmpty else { return (found, nil) }
        do {
            try checkRateLimit()
        } catch {
            return (found, error)
        }

        // Chunked because ``CuratedTrailQuery/geometryQuery(ids:)`` answers
        // about at most a batch at a time and drops the rest silently, and a
        // map can hold more curated pins than one batch holds routes.
        for chunk in missing.chunks(ofCount: CuratedTrailQuery.geometryBatchLimit) {
            do {
                found.merge(try await fetch(Array(chunk))) { _, fetched in fetched }
            } catch {
                // A second chunk refused keeps the first one's lines, and
                // stops: the refusal is about the address rather than about
                // the chunk, so the ones after it would be refused too.
                return (found, error)
            }
        }
        return (found, nil)
    }

    /// One geometry pass over `ids`, cached in memory and written to disk.
    ///
    /// Split from ``trails(of:)`` so that the loop above is about *what a
    /// refusal costs* and this is about what one answer holds. Answers only
    /// what Overpass drew, which is what keeps the caller's own dictionary
    /// built from the fetch rather than read back out of a cache this may
    /// already have evicted from.
    private func fetch(_ ids: [Int64]) async throws -> [Int64: CuratedTrail] {
        guard let query = CuratedTrailQuery.geometryQuery(ids: ids) else { return [:] }
        let decoded = try CuratedTrailDecoding.trails(fromGeometry: try await send(query))
        var found: [Int64: CuratedTrail] = [:]
        // Collected and written once at the end rather than one at a time: a
        // per-route write re-enumerates the cache directory per route — see
        // ``CuratedTrailStore/save(_:)-([CuratedTrail])``.
        var fetched: [CuratedTrail] = []
        for relationID in ids {
            // An id the response did not carry is one Overpass has nothing to
            // draw for — deleted, or too fragmented to assemble. That is an
            // answer, and it is cached as one.
            guard let trail = decoded[relationID] else {
                // In memory only, deliberately: see ``CuratedTrailStore`` on
                // why *nothing here* is not a thing to write down for thirty
                // days.
                cache(.absent, for: relationID)
                continue
            }
            found[relationID] = trail
            cache(.trail(trail), for: relationID)
            fetched.append(trail)
        }
        store?.save(fetched)
        return found
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
