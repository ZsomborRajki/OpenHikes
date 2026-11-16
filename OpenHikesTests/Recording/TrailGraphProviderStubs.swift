//
//  TrailGraphProviderStubs.swift
//  OpenHikesTests
//
//  Trail graph providers standing in for Overpass: one that always answers
//  from a fixed graph, one that fails a scripted number of times first, one
//  that only ever refuses, one that counts how often it was asked, and one
//  whose two regions can be withheld, restored and replaced.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared

actor StubTrailGraphProvider: TrailGraphProviding {
    let graph: TrailGraph
    let cachedGraphDelay: Duration?
    private var prefetchedRegions: [TrailGraphRegion] = []

    init(
        graph: TrailGraph,
        cachedGraphDelay: Duration? = nil
    ) {
        self.graph = graph
        self.cachedGraphDelay = cachedGraphDelay
    }

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        guard Mercator.isRepresentable(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) else { return nil }
        return TrailGraphRegion(
            zoom: 12,
            x: Int(floor((coordinate.longitude + 180) * 10)),
            y: Int(floor((coordinate.latitude + 90) * 10))
        )
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) {
        if let region = region(containing: coordinate) {
            prefetchedRegions.append(region)
        }
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) async throws -> TrailGraph? {
        if let cachedGraphDelay {
            try await Task.sleep(for: cachedGraphDelay)
        }
        return graph
    }

    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        true
    }

    func prefetches() -> [TrailGraphRegion] {
        prefetchedRegions
    }
}

actor ScriptedTrailGraphProvider: TrailGraphProviding {
    private let failuresBeforeSuccess: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        TrailGraphRegion(zoom: 12, x: 1, y: 1)
    }

    func prefetch(
        around coordinate: CLLocationCoordinate2D
    ) async throws {
        attempts += 1
        await Task.yield()
        if attempts <= failuresBeforeSuccess { throw URLError(.notConnectedToInternet) }
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> TrailGraph? {
        .empty
    }

    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        true
    }

    func attemptCount() -> Int {
        attempts
    }
}

/// Throws `CancellationError` of its own accord, without the calling task ever
/// being cancelled.
///
/// That is the one shape in which a cancelled prefetch can strand its region:
/// `cancelTrailGraphPrefetches()` clears every state right after cancelling, so
/// its own cancellations are always tidied up, and only a provider that
/// reports cancellation unprompted reaches the `catch is CancellationError`
/// path with the recorder's bookkeeping still live.
actor CancellingTrailGraphProvider: TrailGraphProviding {
    private var attempts = 0

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        TrailGraphRegion(zoom: 12, x: 1, y: 1)
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) async throws {
        attempts += 1
        await Task.yield()
        throw CancellationError()
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> TrailGraph? {
        nil
    }

    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        false
    }

    func attemptCount() -> Int {
        attempts
    }
}

/// Refuses every fetch with the same Overpass failure, for ever.
///
/// The three shapes a busy Overpass produces — a `429` with its `Retry-After`,
/// a `504` from the dispatcher in front of it, and the abandoned query that
/// arrives dressed as a `200` — are all one enumeration away from each other,
/// so one provider parameterised by the error covers all of them. Answers
/// `nil` from the cache as well, which is what makes
/// ``TrailGraphProviding/graph(covering:)`` rethrow rather than hand back a
/// partial graph.
actor RefusingTrailGraphProvider: TrailGraphProviding {
    private let error: TrailGraphProviderError
    private var attempts = 0

    init(error: TrailGraphProviderError) {
        self.error = error
    }

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        TrailGraphRegion(zoom: 12, x: 1, y: 1)
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) async throws {
        attempts += 1
        await Task.yield()
        throw error
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> TrailGraph? {
        nil
    }

    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        false
    }

    func attemptCount() -> Int {
        attempts
    }
}

/// Answers from a fixed graph and counts how many times it was read.
///
/// The seam a caching claim is checked through: a cache that is not consulted
/// is indistinguishable from one that is, except in how often the thing behind
/// it is asked.
actor CountingTrailGraphProvider: TrailGraphProviding {
    private let graph: TrailGraph
    private var fetches = 0

    init(graph: TrailGraph) {
        self.graph = graph
    }

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        TrailGraphRegion(zoom: 12, x: 1, y: 1)
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) {
        // Nothing to download: the graph is already here.
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> TrailGraph? {
        fetches += 1
        return graph
    }

    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        true
    }

    func fetchCount() -> Int {
        fetches
    }
}

/// Two regions either side of a line of longitude, each answered from a graph
/// of its own: a region can be withheld until a suite restores it, and a
/// region's graph can be replaced.
///
/// What a drawn leg meets in the real provider and the fixed stubs above
/// cannot show it: a region on disk beside one the network refused, and a
/// region that arrives, or changes, after a leg has been routed without it.
actor RegionalTrailGraphProvider: TrailGraphProviding {
    /// West of it is ``west``, and the rest ``east``.
    nonisolated static let boundaryLongitude = 12.8
    nonisolated static let west = TrailGraphRegion(zoom: 12, x: 0, y: 0)
    nonisolated static let east = TrailGraphRegion(zoom: 12, x: 1, y: 0)

    private var graphs: [TrailGraphRegion: TrailGraph]
    private var withheld: Set<TrailGraphRegion>

    init(
        graphs: [TrailGraphRegion: TrailGraph],
        withholding withheld: Set<TrailGraphRegion> = []
    ) {
        self.graphs = graphs
        self.withheld = withheld
    }

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        coordinate.longitude < Self.boundaryLongitude ? Self.west : Self.east
    }

    /// A withheld region fails the way a phone with no signal does.
    func prefetch(around coordinate: CLLocationCoordinate2D) throws {
        guard let region = region(containing: coordinate), withheld.contains(region) else { return }
        throw URLError(.notConnectedToInternet)
    }

    /// Every region the coordinates cross that is not withheld, merged west
    /// to east, so the same regions make the same graph every time.
    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> TrailGraph? {
        let regions = Set(coordinates.compactMap(region(containing:))).subtracting(withheld)
        var merged: TrailGraph?
        for region in regions.sorted(by: { $0.x < $1.x }) {
            guard let graph = graphs[region] else { continue }
            merged = merged?.merging(graph) ?? graph
        }
        return merged
    }

    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        Set(coordinates.compactMap(region(containing:))).isDisjoint(with: withheld)
    }

    /// The region arriving, as when the signal comes back.
    func restore(_ region: TrailGraphRegion) {
        withheld.remove(region)
    }

    /// The region refreshed with what OpenStreetMap holds now.
    func replace(_ graph: TrailGraph, in region: TrailGraphRegion) {
        graphs[region] = graph
    }
}
