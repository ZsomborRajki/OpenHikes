//
//  OverpassTrailGraphProvider.swift
//  OpenTrails
//
//  Bounded OSM trail-graph prefetch and durable cache. Only the map region is
//  sent to Overpass; the recorded trace never leaves the device.
//

import Algorithms
import CoreLocation
import Foundation
import OpenTrailsShared

nonisolated struct TrailGraphRegion: Codable, Hashable, Sendable {
    let zoom: Int
    let x: Int
    let y: Int
}

nonisolated protocol TrailGraphProviding: Sendable {
    func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion?
    func prefetch(around coordinate: CLLocationCoordinate2D) async throws
    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) async throws -> TrailGraph?
}

nonisolated enum TrailGraphProviderError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case malformedGraph(String)
    case rateLimited(retryAfter: TimeInterval)
    case server(statusCode: Int)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Overpass returned an invalid response."
        case .server(let statusCode): "Overpass returned HTTP \(statusCode)."
        case .rateLimited: "Overpass temporarily rate-limited trail downloads."
        case .malformedGraph: "The downloaded trail graph could not be decoded."
        case .storage: "The trail graph cache could not be updated."
        }
    }
}

nonisolated struct OverpassHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
}

actor OverpassTrailGraphProvider: TrailGraphProviding {
    typealias Transport = @Sendable (URLRequest) async throws
        -> OverpassHTTPResponse

    private static let cacheZoom = 12
    private static let cacheLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumCacheFiles = 64
    private static let requestTimeoutInterval: TimeInterval = 35
    private static let defaultRetryDelay: TimeInterval = 60
    private static let httpSuccessRange = 200..<300
    private static let httpRateLimitCode = 429
    private static let allowedHighways: Set<String> = [
        "path", "footway", "track", "bridleway", "steps", "cycleway",
        "via_ferrata",
    ]

    private struct CachedGraph: Codable, Sendable {
        let fetchedAt: Date
        let graph: TrailGraph
    }

    private struct BoundingBox: Sendable {
        let south: Double
        let west: Double
        let north: Double
        let east: Double
    }

    private let directory: URL
    private let endpoint: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date
    private var memory: [TrailGraphRegion: CachedGraph] = [:]
    private var inFlight: [TrailGraphRegion: Task<TrailGraph, Error>] = [:]
    private var retryAfter: Date?

    init(
        directory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        .first?
        .appendingPathComponent("TrailGraphs", isDirectory: true),
        endpoint: URL = URL(
            string: "https://overpass-api.de/api/interpreter"
        )!,
        clock: @escaping @Sendable () -> Date = { Date() },
        transport: Transport? = nil
    ) {
        self.directory = directory
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenTrails-TrailGraphs", isDirectory: true)
        self.endpoint = endpoint
        self.clock = clock
        self.transport = transport ?? { request in
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw TrailGraphProviderError.invalidResponse
            }
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headers[String(describing: key).lowercased()]
                    = String(describing: value)
            }
            return OverpassHTTPResponse(
                data: data,
                statusCode: httpResponse.statusCode,
                headers: headers
            )
        }
    }

    nonisolated func region(
        containing coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion? {
        guard Mercator.isRepresentable(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ) else { return nil }
        return Self.regionKey(for: coordinate)
    }

    func prefetch(around coordinate: CLLocationCoordinate2D) async throws {
        guard let key = region(containing: coordinate) else { return }
        if try cachedGraph(for: key, allowExpired: false) != nil { return }
        if let task = inFlight[key] {
            _ = try await task.value
            return
        }
        if let retryAfter, retryAfter > clock() {
            throw TrailGraphProviderError.rateLimited(
                retryAfter: retryAfter.timeIntervalSince(clock())
            )
        }

        let capturedEndpoint = endpoint
        let capturedTransport = transport
        let task = Task {
            try await Self.fetchGraph(
                for: key,
                endpoint: capturedEndpoint,
                transport: capturedTransport
            )
        }
        inFlight[key] = task

        do {
            let graph = try await task.value
            inFlight[key] = nil
            let cached = CachedGraph(fetchedAt: clock(), graph: graph)
            memory[key] = cached
            try write(cached, for: key)
            trimCache()
        } catch let error as TrailGraphProviderError {
            inFlight[key] = nil
            if case .rateLimited(let delay) = error {
                let candidate = clock().addingTimeInterval(delay)
                retryAfter = max(retryAfter ?? .distantPast, candidate)
            }
            throw error
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func cachedGraph(
        covering coordinates: [CLLocationCoordinate2D]
    ) async throws -> TrailGraph? {
        let keys = Set(coordinates.compactMap(region(containing:)))
        guard !keys.isEmpty else { return nil }

        var combined: TrailGraph?
        for key in keys {
            let resolvedGraph: TrailGraph?
            if let cached = try cachedGraph(
                for: key,
                allowExpired: false
            ) {
                resolvedGraph = cached.graph
            } else if let task = inFlight[key] {
                do {
                    resolvedGraph = try await task.value
                } catch {
                    if let expired = try cachedGraph(
                        for: key,
                        allowExpired: true
                    ) {
                        resolvedGraph = expired.graph
                    } else {
                        throw error
                    }
                }
            } else if let expired = try cachedGraph(
                for: key,
                allowExpired: true
            ) {
                resolvedGraph = expired.graph
            } else {
                resolvedGraph = nil
            }

            if let resolvedGraph {
                combined = combined?.merging(resolvedGraph) ?? resolvedGraph
            }
        }
        return combined
    }

    private func cachedGraph(
        for key: TrailGraphRegion,
        allowExpired: Bool
    ) throws -> CachedGraph? {
        if let cached = memory[key] {
            if allowExpired || clock().timeIntervalSince(cached.fetchedAt)
                <= Self.cacheLifetime { return cached }
            return nil
        }

        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let cached = try JSONDecoder().decode(
                CachedGraph.self,
                from: Data(contentsOf: url)
            )
            guard allowExpired
                || clock().timeIntervalSince(cached.fetchedAt)
                    <= Self.cacheLifetime
            else { return nil }
            memory[key] = cached
            return cached
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw TrailGraphProviderError.storage(error.localizedDescription)
        }
    }

    private func write(
        _ cached: CachedGraph,
        for key: TrailGraphRegion
    ) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(cached).write(
                to: fileURL(for: key),
                options: .atomic
            )
        } catch {
            throw TrailGraphProviderError.storage(error.localizedDescription)
        }
    }

    private func trimCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > Self.maximumCacheFiles else { return }
        let mapped = files.map { url in
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        let doomed = mapped
            .min(count: files.count - Self.maximumCacheFiles) { $0.1 < $1.1 }
        for (url, _) in doomed {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for key: TrailGraphRegion) -> URL {
        directory.appendingPathComponent(
            "\(key.zoom)-\(key.x)-\(key.y).json"
        )
    }
}

// MARK: - Static helpers

private extension OverpassTrailGraphProvider {
    nonisolated static func regionKey(
        for coordinate: CLLocationCoordinate2D
    ) -> TrailGraphRegion {
        let count = 1 << cacheZoom
        return TrailGraphRegion(
            zoom: cacheZoom,
            x: SlippyTileMath.wrap(
                SlippyTileMath.tileX(coordinate.longitude, z: cacheZoom),
                to: count
            ),
            y: SlippyTileMath.clamp(
                SlippyTileMath.tileY(coordinate.latitude, z: cacheZoom),
                to: count
            )
        )
    }

    nonisolated static func fetchGraph(
        for key: TrailGraphRegion,
        endpoint: URL,
        transport: Transport
    ) async throws -> TrailGraph {
        let box = BoundingBox(
            south: SlippyTileMath.lat(y: key.y + 1, z: key.zoom),
            west: SlippyTileMath.lon(x: key.x, z: key.zoom),
            north: SlippyTileMath.lat(y: key.y, z: key.zoom),
            east: SlippyTileMath.lon(x: key.x + 1, z: key.zoom)
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutInterval
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(TileCache.userAgent, forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "data", value: query(for: box))
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let response = try await transport(request)
        switch response.statusCode {
        case httpSuccessRange: return try decodeGraph(from: response.data)
        case httpRateLimitCode:
            let delay = response.headers["retry-after"]
                .flatMap(TimeInterval.init) ?? defaultRetryDelay
            throw TrailGraphProviderError.rateLimited(retryAfter: delay)
        default: throw TrailGraphProviderError.server(statusCode: response.statusCode)
        }
    }

    nonisolated private static func query(for box: BoundingBox) -> String {
        let bounds = "\(box.south),\(box.west),\(box.north),\(box.east)"
        return """
        [out:json][timeout:25];
        way["highway"~"^(path|footway|track|bridleway|steps|cycleway|via_ferrata)$"](\(bounds))->.trails;
        rel(bw.trails)["route"="hiking"]->.routes;
        node(w.trails)->.trailNodes;
        (.trails;.routes;.trailNodes;);
        out body;
        """
    }

    nonisolated static func decodeGraph(from data: Data) throws -> TrailGraph {
        let response: OverpassResponse
        do {
            response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        } catch {
            throw TrailGraphProviderError.malformedGraph(
                error.localizedDescription
            )
        }

        let elementsByKey = buildElementIndex(from: response.elements)
        let nodeCoordinates = extractNodeCoordinates(from: response.elements)
        let hikingRouteNames = extractHikingRouteNames(from: elementsByKey)
        let (graphNodes, edges) = buildGraphEdges(
            from: elementsByKey,
            nodeCoordinates: nodeCoordinates,
            hikingRouteNames: hikingRouteNames
        )

        return TrailGraph(
            nodes: graphNodes.values.sorted { lhs, rhs in lhs.id < rhs.id },
            edges: edges.sorted { lhs, rhs in
                if lhs.id.wayID == rhs.id.wayID { return lhs.id.segmentIndex < rhs.id.segmentIndex }
                return lhs.id.wayID < rhs.id.wayID
            }
        )
    }

    nonisolated static func buildElementIndex(
        from elements: [OverpassElement]
    ) -> [String: OverpassElement] {
        var index: [String: OverpassElement] = [:]
        for element in elements {
            index["\(element.type)/\(element.id)"] = element
        }
        return index
    }

    nonisolated static func extractNodeCoordinates(
        from elements: [OverpassElement]
    ) -> [Int64: CLLocationCoordinate2D] {
        var nodeCoordinates: [Int64: CLLocationCoordinate2D] = [:]
        for element in elements where element.type == "node" {
            guard let lat = element.lat,
                  let lon = element.lon,
                  Mercator.isRepresentable(latitude: lat, longitude: lon)
            else {
                continue
            }
            nodeCoordinates[element.id] = CLLocationCoordinate2D(
                latitude: lat,
                longitude: lon
            )
        }
        return nodeCoordinates
    }

    nonisolated static func extractHikingRouteNames(
        from elementsByKey: [String: OverpassElement]
    ) -> [Int64: String] {
        var hikingRouteNames: [Int64: String] = [:]
        for element in elementsByKey.values where element.type == "relation" {
            guard element.tags["route"] == "hiking",
                  let name = element.tags["name"] ?? element.tags["ref"]
            else {
                continue
            }
            for member in element.members where member.type == "way" {
                if let existing = hikingRouteNames[member.ref] {
                    hikingRouteNames[member.ref] = min(existing, name)
                } else {
                    hikingRouteNames[member.ref] = name
                }
            }
        }
        return hikingRouteNames
    }

    nonisolated static func buildGraphEdges(
        from elementsByKey: [String: OverpassElement],
        nodeCoordinates: [Int64: CLLocationCoordinate2D],
        hikingRouteNames: [Int64: String]
    ) -> (nodes: [Int64: TrailGraphNode], edges: [TrailGraphEdge]) {
        var graphNodes: [Int64: TrailGraphNode] = [:]
        var edges: [TrailGraphEdge] = []
        for element in elementsByKey.values where element.type == "way" {
            guard let highway = element.tags["highway"],
                  allowedHighways.contains(highway),
                  element.nodes.count > 1,
                  permitsWalking(element.tags)
            else {
                continue
            }

            let nodeIDs = element.nodes
            for index in 0..<(nodeIDs.count - 1) {
                let fromID = nodeIDs[index]
                let toID = nodeIDs[index + 1]
                guard fromID != toID,
                      let from = nodeCoordinates[fromID],
                      let to = nodeCoordinates[toID]
                else {
                    continue
                }
                let length = RouteGeometry.distanceMeters(from: from, to: to)
                guard length.isFinite, length > 0 else { continue }
                graphNodes[fromID] = TrailGraphNode(id: fromID, coordinate: from)
                graphNodes[toID] = TrailGraphNode(id: toID, coordinate: to)
                edges.append(
                    TrailGraphEdge(
                        id: TrailGraphEdgeID(wayID: element.id, segmentIndex: index),
                        fromNodeID: fromID,
                        toNodeID: toID,
                        lengthMeters: length,
                        name: element.tags["name"],
                        hikingRouteName: hikingRouteNames[element.id],
                        sacScale: element.tags["sac_scale"],
                        trailVisibility: element.tags["trail_visibility"],
                        access: element.tags["access"],
                        surface: element.tags["surface"]
                    )
                )
            }
        }
        return (graphNodes, edges)
    }

    nonisolated static func permitsWalking(
        _ tags: [String: String]
    ) -> Bool {
        if let foot = tags["foot"], foot == "no" || foot == "private" { return false }
        guard let access = tags["access"],
              access == "no" || access == "private"
        else { return true }
        return ["yes", "designated", "permissive"].contains(tags["foot"])
    }
}
