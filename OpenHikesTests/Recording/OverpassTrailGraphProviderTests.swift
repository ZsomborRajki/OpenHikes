//
//  OverpassTrailGraphProviderTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

private actor OverpassRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

nonisolated private enum RateLimitFixture {
    static let statusCode = 429
    static let responseCount = 2
}

private actor ConsecutiveRateLimitTransport {
    private(set) var requestCount = 0

    func response() async -> OverpassHTTPResponse {
        requestCount += 1
        let requestIndex = requestCount
        if requestIndex == 1 {
            while requestCount < RateLimitFixture.responseCount {
                await Task.yield()
            }
            return OverpassHTTPResponse(
                data: Data(),
                statusCode: RateLimitFixture.statusCode,
                headers: ["retry-after": "120"]
            )
        }
        try? await Task.sleep(for: .milliseconds(25))
        return OverpassHTTPResponse(
            data: Data(),
            statusCode: RateLimitFixture.statusCode,
            headers: ["retry-after": "10"]
        )
    }
}

@Suite("Overpass trail graph")
struct OverpassTrailGraphProviderTests {
    @Test("region identity changes exactly at the cache-tile boundary")
    func regionIdentityTracksCoverage() throws {
        let provider = OverpassTrailGraphProvider()
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )
        let initial = try #require(
            provider.region(containing: coordinate)
        )
        let eastBoundary = SlippyTileMath.lon(
            x: initial.x + 1,
            z: initial.zoom
        )
        let adjacent = try #require(
            provider.region(
                containing: CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: eastBoundary + 0.000001
                )
            )
        )

        #expect(adjacent != initial)
        #expect(adjacent.x == initial.x + 1)
    }

    @Test("OSM ways become junction edges with hiking relation names")
    func decodesGraph() throws {
        let graph = try OverpassTrailGraphProvider.decodeGraph(
            from: Data(Self.fixture.utf8)
        )

        #expect(graph.nodes.count == 2)
        #expect(graph.edges.count == 1)
        let edge = try #require(graph.edges.first)
        #expect(edge.name == "Local Path")
        #expect(edge.hikingRouteName == "Alpine Route")
        #expect(edge.displayName == "Alpine Route")
        #expect(edge.surface == "gravel")
        #expect(edge.tracktype == "grade2")
    }

    @Test("prefetch identifies itself, is bounded, and reuses its disk cache")
    func prefetchAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "trail-graph-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OverpassRequestRecorder()
        let clock = TestClock()
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { request in
            await recorder.record(request)
            return OverpassHTTPResponse(
                data: Data(Self.fixture.utf8),
                statusCode: 200,
                headers: [:]
            )
        }
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )

        try await provider.prefetch(around: coordinate)
        try await provider.prefetch(around: coordinate)

        let requests = await recorder.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        try assertOverpassQueryShape(request)

        clock.advance(by: 31 * 24 * 60 * 60)
        let reloaded = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in
            Issue.record(
                "offline matching should still use an expired durable graph"
            )
            return OverpassHTTPResponse(
                data: Data(),
                statusCode: 500,
                headers: [:]
            )
        }
        let graph = try await reloaded.cachedGraph(covering: [coordinate])
        #expect(graph?.edges.count == 1)
    }

    @Test("a final cache read waits for its in-flight prefetch")
    func cacheReadAwaitsPrefetch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "trail-graph-in-flight-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OverpassRequestRecorder()
        let transport: OverpassTrailGraphProvider.Transport = { request in
            await recorder.record(request)
            try await Task.sleep(for: .milliseconds(50))
            return OverpassHTTPResponse(
                data: Data(Self.fixture.utf8),
                statusCode: 200,
                headers: [:]
            )
        }
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            transport: transport
        )
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )

        let prefetch = Task {
            try await provider.prefetch(around: coordinate)
        }
        for _ in 0..<100 {
            if !(await recorder.requests).isEmpty { break }
            await Task.yield()
        }
        let graph = try await provider.cachedGraph(
            covering: [coordinate]
        )
        try await prefetch.value

        #expect(graph?.edges.count == 1)
    }

    @Test("an in-flight refresh wins over an expired graph")
    func refreshReplacesExpiredGraph() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "trail-graph-refresh-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = OverpassRequestRecorder()
        let clock = TestClock()
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { request in
            await recorder.record(request)
            if (await recorder.requests).count > 1 {
                try await Task.sleep(for: .milliseconds(50))
                return OverpassHTTPResponse(
                    data: Data(#"{"elements":[]}"#.utf8),
                    statusCode: 200,
                    headers: [:]
                )
            }
            return OverpassHTTPResponse(
                data: Data(Self.fixture.utf8),
                statusCode: 200,
                headers: [:]
            )
        }
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )
        try await provider.prefetch(around: coordinate)
        clock.advance(by: 31 * 24 * 60 * 60)

        let refresh = Task {
            try await provider.prefetch(around: coordinate)
        }
        for _ in 0..<100 {
            if (await recorder.requests).count == 2 { break }
            await Task.yield()
        }
        let graph = try await provider.cachedGraph(
            covering: [coordinate]
        )
        try await refresh.value

        #expect(graph?.edges.isEmpty == true)
    }

    @Test("consecutive 429s preserve the longest retry floor")
    func repeatedRateLimitsKeepLongestFloor() async throws {
        let transport = ConsecutiveRateLimitTransport()
        let clock = TestClock()
        let provider = OverpassTrailGraphProvider(
            clock: clock.read
        ) { _ in
            await transport.response()
        }
        let first = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )
        let region = try #require(provider.region(containing: first))
        let second = CLLocationCoordinate2D(
            latitude: first.latitude,
            longitude: SlippyTileMath.lon(
                x: region.x + 1,
                z: region.zoom
            ) + 0.000001
        )
        let third = CLLocationCoordinate2D(
            latitude: first.latitude,
            longitude: SlippyTileMath.lon(
                x: region.x + 2,
                z: region.zoom
            ) + 0.000001
        )

        let firstRequest = Task {
            try await provider.prefetch(around: first)
        }
        let secondRequest = Task {
            try await provider.prefetch(around: second)
        }
        for request in [firstRequest, secondRequest] {
            do {
                try await request.value
                Issue.record("A scripted 429 unexpectedly succeeded.")
            } catch let error as TrailGraphProviderError {
                guard case .rateLimited = error else {
                    Issue.record("Expected a rate-limit error, got \(error).")
                    continue
                }
            }
        }

        do {
            try await provider.prefetch(around: third)
            Issue.record("The provider ignored its retry floor.")
        } catch let error as TrailGraphProviderError {
            guard case .rateLimited(let retryAfter) = error else {
                Issue.record("Expected a rate-limit error, got \(error).")
                return
            }
            #expect(retryAfter == 120)
        }
        #expect(await transport.requestCount == 2)
    }

    private func assertOverpassQueryShape(_ request: URLRequest) throws {
        #expect(request.httpMethod == "POST")
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")
                == TileCache.userAgent
        )
        let body = try #require(
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        #expect(body.contains("highway"))
        #expect(body.contains("route%22%3D%22hiking"))
        let form = URLComponents(string: "?\(body)")
        let query = try #require(
            form?.queryItems?.first { $0.name == "data" }?.value
        )
        #expect(query.contains("rel(bw.trails)"))
        #expect(query.contains("node(w.trails)"))
        #expect(!query.contains(">>"))
    }

    nonisolated private static let fixture = """
        {
            "elements": [
                {"type":"node","id":1,"lat":47.6300,"lon":12.8600},
                {"type":"node","id":2,"lat":47.6310,"lon":12.8600},
                {"type":"node","id":3,"lat":47.6320,"lon":12.8600},
                {
                    "type":"way",
                    "id":10,
                    "nodes":[1,2],
                    "tags":{
                        "highway":"path",
                        "name":"Local Path",
                        "surface":"gravel",
                        "tracktype":"grade2"
                    }
                },
                {
                    "type":"way",
                    "id":11,
                    "nodes":[2,3],
                    "tags":{
                        "highway":"path",
                        "access":"private"
                    }
                },
                {
                    "type":"relation",
                    "id":100,
                    "members":[{"type":"way","ref":10,"role":""}],
                    "tags":{"route":"hiking","name":"Alpine Route"}
                }
            ]
        }
        """
}
