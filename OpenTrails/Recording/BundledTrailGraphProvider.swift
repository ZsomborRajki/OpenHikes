//
//  BundledTrailGraphProvider.swift
//  OpenTrails
//
//  A trail graph that ships with the app instead of arriving from Overpass.
//  UI automation needs route review to happen the same way every run, and a
//  network round trip is neither offline-safe nor deterministic. Nothing
//  constructs this outside the `--ui-test-trail-graph=` launch argument.
//

import CoreLocation
import Foundation

nonisolated struct BundledTrailGraphProvider: TrailGraphProviding {
    private let graph: TrailGraph

    init?(fixtureName: String, bundle: Bundle = .main) {
        guard let url = bundle.url(
            forResource: fixtureName,
            withExtension: "json"
        ),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(TrailGraph.self, from: data),
            !decoded.isEmpty else { return nil }
        graph = decoded
    }

    /// No region bookkeeping: the fixture covers wherever the test walks, so
    /// there is nothing to prefetch and nothing to key a prefetch by.
    func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        nil
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) {
        // The graph is already on disk.
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> TrailGraph? {
        graph
    }

    /// Always complete: the fixture is the whole world this provider knows,
    /// and there is no network behind it to fill a gap from.
    func hasCompleteCachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        true
    }
}
