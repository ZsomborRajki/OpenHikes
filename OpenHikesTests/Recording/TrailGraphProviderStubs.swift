//
//  TrailGraphProviderStubs.swift
//  OpenHikesTests
//
//  Trail graph providers standing in for Overpass: one that always answers
//  from a fixed graph, one that fails a scripted number of times first.
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
