//
//  StubCuratedTrailSource.swift
//  OpenHikesTests
//
//  What the curated half of the community list answers instead of Overpass.
//
//  Its own file rather than the bottom of `MergedCommunityTransportTests`,
//  which is where it started: a second suite now needs it — the scope a nearby
//  question carries is asserted by watching this stay quiet — and a stub two
//  suites share is a stub neither of them owns. It sits beside
//  `StubCommunityTransport` for the same reason that one is a file of its own.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization

/// What the curated half answers instead of Overpass.
///
/// A stub for the reason ``StubCommunityTransport`` is one, and a sharper one:
/// the real conformance reaches a **volunteer-run** public API on a quota
/// shared by every copy of this app, over which a test suite has no claim at
/// all. See ``CuratedTrailSourcing``.
///
/// `final class` behind a `Mutex` rather than an actor, for the same reason
/// the published stub is one: the protocol's requirements are `@concurrent`,
/// so calls genuinely arrive off the main actor, and an actor would turn every
/// recording read in a test into a suspension point the next request could
/// overtake.
final class StubCuratedTrailSource: CuratedTrailSourcing, @unchecked Sendable {
    struct Recording: Sendable {
        /// The areas a nearby search asked about and the limit each carried.
        /// What proves the composite hands this half the same question it
        /// hands CloudKit rather than one of its own devising.
        var areaRequests: [(area: CommunitySearchArea, limit: Int)] = []
        var titleQueries: [String] = []
        /// The relations a per-route request asked about, in order. What
        /// proves a CloudKit record name never arrives here.
        var trailRequests: [Int64] = []
        /// How many routes each geometry pass was asked to complete. The
        /// expensive half of a search, and the one the published rows are
        /// supposed to have already spent the limit on.
        var completionSizes: [Int] = []

        /// Whether this source was asked nothing at all — the assertion every
        /// published-only path in this file ends on.
        /// The areas a refused search fell back to this device's own routes
        /// about. Not part of ``isQuiet``: reading what is already here is not
        /// reaching Overpass, which is what that flag is about.
        var cacheReads: [CommunitySearchArea] = []

        var isQuiet: Bool {
            areaRequests.isEmpty && titleQueries.isEmpty && trailRequests.isEmpty
                && completionSizes.isEmpty
        }
    }

    /// What an area search answers. A failure is Overpass refusing — a `429`,
    /// or an overloaded server's HTML page — which is the ordinary condition
    /// the merge is built to survive rather than an exotic one.
    var nearbyResult: Result<[CuratedTrail], TrailGraphProviderError> = .success([])

    /// What the geometry pass does, which is a different question from what
    /// the listing pass does and has to be armed separately: the case worth
    /// testing is the one where the cheap pass got through and the expensive
    /// one did not.
    enum GeometryResult: Sendable {
        /// Every line arrives. The default, and what a case that has not
        /// thought about Overpass refusing should get.
        case drawn
        /// The rows come back without their lines, and the refusal beside
        /// them — the real source's answer to a refused geometry pass.
        case refused(CuratedTrailOutage)
        /// Nothing comes back at all. A conformance may still throw, and a
        /// cancellation does.
        case thrown(any Error)
    }

    var geometryResult: GeometryResult = .drawn

    /// Every route this source knows, by relation. A relation absent from here
    /// is one OSM no longer has, which is a real and unremarkable state: ids
    /// are stable but not permanent.
    private var known: [Int64: CuratedTrail] = [:]
    private let trails: [CuratedTrail]
    private let state = Mutex(Recording())

    var recording: Recording { state.withLock { $0 } }

    init(trails: [CuratedTrail] = []) {
        self.trails = trails
        nearbyResult = .success(trails)
        known = Dictionary(uniqueKeysWithValues: trails.map { ($0.relationID, $0) })
    }

    /// Honours `limit` rather than merely recording it, because the real
    /// source does — it never asks for geometry beyond
    /// ``CuratedTrailQuery/geometryBatchLimit`` — and the merge's own split has
    /// to be shown doing its work on top of that rather than instead of it.
    @concurrent
    func listings(near area: CommunitySearchArea, limit: Int) async throws -> [CuratedTrail] {
        state.withLock { $0.areaRequests.append((area: area, limit: limit)) }
        await Task.yield()
        let answer = try nearbyResult.get()
        return Array(answer.prefix(max(0, limit)))
    }

    /// Records how many rows the expensive pass was asked about, which is the
    /// whole point of the pass being separate. The rows come back unchanged
    /// unless a case has armed ``geometryResult``: the stub's trails already
    /// carry their lines, and what is under test here is usually the size of
    /// the question rather than the answer to it.
    @concurrent
    func completed(_ listed: [CuratedTrail]) async throws -> CuratedCompletion {
        state.withLock { $0.completionSizes.append(listed.count) }
        await Task.yield()
        switch geometryResult {
        case .drawn:
            return CuratedCompletion(trails: listed)
        case .refused(let outage):
            // What the real source does with a refused geometry pass: the rows
            // the listing pass paid for, without their lines, and the refusal
            // beside them. See ``CuratedTrailSourcing/completed(_:)``.
            return CuratedCompletion(
                trails: listed.map { trail in
                    var lineless = trail
                    lineless.route = []
                    return lineless
                },
                outage: outage
            )
        case .thrown(let error):
            throw error
        }
    }

    /// Filters by name the way the real source does, so a query written in a
    /// test has to be one that could actually match — a stub that answered
    /// everything would let a merge that never passed the query along look
    /// correct.
    @concurrent
    func trails(matching query: String, limit: Int) async -> [CuratedTrail] {
        state.withLock { $0.titleQueries.append(query) }
        await Task.yield()
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !needle.isEmpty, limit > 0 else { return [] }
        let hits = trails.filter { $0.name.localizedLowercase.contains(needle) }
        return Array(hits.prefix(limit))
    }

    /// What this device is pretending to have downloaded already, for the
    /// path a refused search falls back to. Empty by default, which is the
    /// state of a device that has never searched — and the state that makes
    /// every other case in these suites about Overpass rather than about a
    /// cache.
    var storedTrails: [CuratedTrail] = []

    @concurrent
    func cachedTrails(near area: CommunitySearchArea, limit: Int) async -> [CuratedTrail] {
        state.withLock { $0.cacheReads.append(area) }
        await Task.yield()
        return Array(storedTrails.prefix(max(0, limit)))
    }

    @concurrent
    func trails(of relationIDs: [Int64]) async -> [Int64: CuratedTrail] {
        state.withLock { $0.trailRequests.append(contentsOf: relationIDs) }
        await Task.yield()
        return known.filter { relationIDs.contains($0.key) }
    }
}
