//
//  OverpassTrailGraphProviderTests.swift
//  OpenTrailsTests
//

import CoreLocation
import Foundation
import Testing
@testable import OpenTrails

private actor OverpassRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

@Suite("Overpass trail graph")
struct OverpassTrailGraphProviderTests {
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
                clock: clock.read,
                transport: { request in
                await recorder.record(request)
                return OverpassHTTPResponse(
                    data: Data(Self.fixture.utf8),
                    statusCode: 200,
                    headers: [:]
                )
            }
        )
        let coordinate = CLLocationCoordinate2D(
            latitude: 47.63,
            longitude: 12.86
        )

        try await provider.prefetch(around: coordinate)
        try await provider.prefetch(around: coordinate)

        let requests = await recorder.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
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

        clock.advance(by: 31 * 24 * 60 * 60)
        let reloaded = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read,
            transport: { _ in
                Issue.record(
                    "offline matching should still use an expired durable graph"
                )
                return OverpassHTTPResponse(
                    data: Data(),
                    statusCode: 500,
                    headers: [:]
                )
            }
        )
        let graph = try await reloaded.cachedGraph(covering: [coordinate])
        #expect(graph?.edges.count == 1)
    }

    private nonisolated static let fixture = """
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
            "surface":"gravel"
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
