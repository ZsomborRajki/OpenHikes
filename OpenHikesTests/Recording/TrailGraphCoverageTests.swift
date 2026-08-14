//
//  TrailGraphCoverageTests.swift
//  OpenHikesTests
//
//  Covers assembling a whole route's trail graph, and knowing when what's on
//  disk is enough to measure against.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

private actor GraphRequestRecorder {
    private(set) var count = 0

    /// Records a request and reports which attempt it was, so a transport can
    /// answer the first one differently without a second `await`.
    @discardableResult func record() -> Int {
        count += 1
        return count
    }
}

@Suite("Trail graph coverage")
struct TrailGraphCoverageTests {
    @Test("a route is complete only once every region it crosses is cached")
    func completenessTracksEveryRegionOnTheRoute() async throws {
        let directory = Self.makeDirectory("coverage")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = GraphRequestRecorder()
        let clock = TestClock()
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in
            await recorder.record()
            return OverpassHTTPResponse(
                data: Data(Self.fixture.utf8),
                statusCode: Self.okCode,
                headers: [:]
            )
        }
        let (west, east) = try Self.adjacentRegionCoordinates(for: provider)

        var complete = await provider.hasCompleteCachedGraph(
            covering: [west, east]
        )
        #expect(!complete)

        try await provider.prefetch(around: west)
        // Half a route's worth of graph still merges into a usable match, but
        // it can't measure the half nobody downloaded.
        complete = await provider.hasCompleteCachedGraph(covering: [west, east])
        #expect(!complete)
        #expect(await recorder.count == 1)
        #expect(await provider.hasCompleteCachedGraph(covering: [west]))

        try await provider.prefetch(around: east)
        complete = await provider.hasCompleteCachedGraph(covering: [west, east])
        #expect(complete)
        #expect(await recorder.count == 2)

        // Matching falls back to an expired graph rather than losing the
        // trail; a measurement refetches instead of reporting stale tagging.
        clock.advance(by: Self.beyondCacheLifetime)
        complete = await provider.hasCompleteCachedGraph(covering: [west, east])
        #expect(!complete)
    }

    @Test("assembling a route's graph downloads each missing region once")
    func graphCoveringPrefetchesEachMissingRegion() async throws {
        let directory = Self.makeDirectory("covering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = GraphRequestRecorder()
        let transport: OverpassTrailGraphProvider.Transport = { _ in
            await recorder.record()
            return OverpassHTTPResponse(
                data: Data(Self.fixture.utf8),
                statusCode: Self.okCode,
                headers: [:]
            )
        }
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            transport: transport
        )
        let (west, east) = try Self.adjacentRegionCoordinates(for: provider)

        // Repeated coordinates within a region are one download, not one per
        // track point.
        let graph = try await provider.graph(
            covering: [west, west, east, east, west]
        )

        #expect(await recorder.count == 2)
        #expect(graph?.edges.count == 1)

        // A second pass is served entirely from the cache.
        _ = try await provider.graph(covering: [west, east])
        #expect(await recorder.count == 2)
    }

    @Test("a region that fails still yields the rest of the route's graph")
    func partialFailureStillReturnsWhatDownloaded() async throws {
        let directory = Self.makeDirectory("partial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = GraphRequestRecorder()
        let transport: OverpassTrailGraphProvider.Transport = { _ in
            let attempt = await recorder.record()
            let failed = attempt > 1
            return OverpassHTTPResponse(
                data: failed ? Data() : Data(Self.fixture.utf8),
                statusCode: failed ? Self.serverErrorCode : Self.okCode,
                headers: [:]
            )
        }
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            transport: transport
        )
        let (west, east) = try Self.adjacentRegionCoordinates(for: provider)

        let graph = try await provider.graph(covering: [west, east])

        #expect(graph?.edges.count == 1)
    }

    /// Two coordinates that land either side of a cache-region boundary.
    nonisolated private static func adjacentRegionCoordinates(
        for provider: OverpassTrailGraphProvider
    ) throws -> (west: CLLocationCoordinate2D, east: CLLocationCoordinate2D) {
        let west = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
        let region = try #require(provider.region(containing: west))
        let boundary = SlippyTileMath.lon(x: region.x + 1, z: region.zoom)
        let east = CLLocationCoordinate2D(
            latitude: west.latitude,
            longitude: boundary + Self.pastBoundaryDegrees
        )
        #expect(provider.region(containing: east) != region)
        return (west, east)
    }

    nonisolated private static func makeDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "trail-graph-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    nonisolated private static let okCode = 200
    nonisolated private static let serverErrorCode = 500
    /// Comfortably past the provider's 30-day durable cache lifetime.
    nonisolated private static let beyondCacheLifetime: TimeInterval =
        31 * 24 * 60 * 60
    /// Far enough past a region boundary to be unambiguous, small enough to
    /// stay in the neighbouring region.
    nonisolated private static let pastBoundaryDegrees = 0.001

    nonisolated private static let fixture = """
        {
            "elements": [
                {"type":"node","id":1,"lat":47.6300,"lon":12.8600},
                {"type":"node","id":2,"lat":47.6310,"lon":12.8600},
                {
                    "type":"way",
                    "id":10,
                    "nodes":[1,2],
                    "tags":{"highway":"path","surface":"gravel"}
                }
            ]
        }
        """
}
