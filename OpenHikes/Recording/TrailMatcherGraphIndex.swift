//
//  TrailMatcherGraphIndex.swift
//  OpenHikes
//
//  HMM candidate index used by TrailMatcher.
//

import CoreLocation
import Foundation
import HeapModule
import OrderedCollections

// MARK: - Shared types (used by TrailMatcher and TrailMatcherGraphIndex)

nonisolated struct TrailMatcherCandidate: Comparable {
    let edgeIndex: Int
    let projectedCoordinate: CLLocationCoordinate2D
    let offsetMeters: Double
    let offRouteMeters: Double

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.offRouteMeters == rhs.offRouteMeters
            ? lhs.edgeIndex < rhs.edgeIndex
            : lhs.offRouteMeters < rhs.offRouteMeters
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.offRouteMeters == rhs.offRouteMeters
            && lhs.edgeIndex == rhs.edgeIndex
    }
}

nonisolated struct TrailMatcherTransitionAlternative {
    let distanceMeters: Double
    let coordinates: [CLLocationCoordinate2D]
    let trailNames: [String]
}

nonisolated struct TrailMatcherTransition {
    let distanceMeters: Double
    let coordinates: [CLLocationCoordinate2D]
    let likelihoodMargin: Double
    let trailNames: [String]
    let alternatives: [TrailMatcherTransitionAlternative]
}

nonisolated struct TrailMatcherTransitionParameters {
    let expectedDistance: Double
    let maximumDistance: Double
    let beta: Double
    let isSparse: Bool
    let hasDistanceEvidence: Bool
    let startEndpointTolerance: Double
    let endEndpointTolerance: Double
}

// MARK: - Graph Index

nonisolated struct TrailMatcherGraphIndex {
    struct Adjacency {
        let nodeID: Int64
        let edgeIndex: Int
        let distance: Double
    }

    struct Traversal: Hashable {
        let edgeIndex: Int
        let isForward: Bool
    }

    struct PathOption {
        let distance: Double
        let coordinates: [CLLocationCoordinate2D]
        let signature: [Traversal]
        let trailNames: [String]
    }

    struct Endpoint {
        let nodeID: Int64
        let cost: Double
    }

    struct EdgeEndpoints {
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
    }

    let nodes: [Int64: TrailGraphNode]
    let edges: [TrailGraphEdge]
    let edgeEndpoints: [EdgeEndpoints]
    let adjacency: [Int64: [Adjacency]]
    let grid: EdgeGrid
    var shortestPathCache: [NodePair: NodePath] = [:]

    init(graph: TrailGraph) {
        let nodeMap = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { node in (node.id, node) }
        )
        var validEdges: [TrailGraphEdge] = []
        var endpoints: [EdgeEndpoints] = []
        validEdges.reserveCapacity(graph.edges.count)
        endpoints.reserveCapacity(graph.edges.count)
        for edge in graph.edges {
            guard let start = nodeMap[edge.fromNodeID]?.coordinate,
                  let end = nodeMap[edge.toNodeID]?.coordinate else { continue }
            validEdges.append(edge)
            endpoints.append(EdgeEndpoints(start: start, end: end))
        }
        nodes = nodeMap
        edges = validEdges
        edgeEndpoints = endpoints
        grid = EdgeGrid(endpoints: endpoints)
        var adjacencyMap: [Int64: [Adjacency]] = [:]
        for (edgeIndex, edge) in validEdges.enumerated() {
            adjacencyMap[edge.fromNodeID, default: []].append(
                Adjacency(
                    nodeID: edge.toNodeID,
                    edgeIndex: edgeIndex,
                    distance: edge.lengthMeters
                )
            )
            adjacencyMap[edge.toNodeID, default: []].append(
                Adjacency(
                    nodeID: edge.fromNodeID,
                    edgeIndex: edgeIndex,
                    distance: edge.lengthMeters
                )
            )
        }
        adjacency = adjacencyMap
    }
}

// MARK: - Candidate lookup

nonisolated extension TrailMatcherGraphIndex {
    private static let candidateSearchRadiusMeters = 50.0
    private static let candidateSearchAccuracyFactor = 3.0

    func candidates(for point: RecordingPoint) -> [TrailMatcherCandidate] {
        let radius = max(
            Self.candidateSearchRadiusMeters,
            point.horizontalAccuracy * Self.candidateSearchAccuracyFactor
        )
        var closest = Heap<TrailMatcherCandidate>()
        grid.forEachEdge(near: point.coordinate, within: radius) { edgeIndex in
            let ep = edgeEndpoints[edgeIndex]
            let projection = RouteGeometry.project(
                point.coordinate,
                onSegmentFrom: ep.start,
                to: ep.end
            )
            guard projection.offRouteMeters <= radius else { return }
            closest.insert(
                TrailMatcherCandidate(
                    edgeIndex: edgeIndex,
                    projectedCoordinate: RouteGeometry.interpolate(
                        from: ep.start,
                        to: ep.end,
                        fraction: projection.fraction
                    ),
                    offsetMeters: edges[edgeIndex].lengthMeters * projection.fraction,
                    offRouteMeters: projection.offRouteMeters
                )
            )
            if closest.count > TrailMatcher.maximumCandidatesPerFix {
                closest.removeMax()
            }
        }
        var result: [TrailMatcherCandidate] = []
        result.reserveCapacity(closest.count)
        while let next = closest.popMin() { result.append(next) }
        return result
    }
}

// MARK: - Transition lookup

nonisolated extension TrailMatcherGraphIndex {
    private static let similarityThresholdFraction = 0.15

    mutating func transition(
        from start: TrailMatcherCandidate,
        to end: TrailMatcherCandidate,
        parameters: TrailMatcherTransitionParameters
    ) -> TrailMatcherTransition? {
        var options: [PathOption] = []
        let startEdge = edges[start.edgeIndex]
        let endEdge = edges[end.edgeIndex]
        if start.edgeIndex == end.edgeIndex {
            options.append(
                PathOption(
                    distance: abs(end.offsetMeters - start.offsetMeters),
                    coordinates: [start.projectedCoordinate, end.projectedCoordinate],
                    signature: [
                        Traversal(
                            edgeIndex: start.edgeIndex,
                            isForward: end.offsetMeters >= start.offsetMeters
                        ),
                    ],
                    trailNames: startEdge.displayName.map { [$0] } ?? []
                )
            )
        }
        options.append(contentsOf: collectNodePathOptions(
            from: start,
            to: end,
            startEdge: startEdge,
            endEdge: endEdge,
            parameters: parameters
        ))
        var unique: OrderedDictionary<[Traversal], PathOption> = [:]
        for option in options where option.distance <= parameters.maximumDistance {
            if let existing = unique[option.signature] {
                if option.distance < existing.distance {
                    unique[option.signature] = option
                }
            } else {
                unique[option.signature] = option
            }
        }
        let ranked = unique.values.sorted { lhs, rhs in
            let lhsError = abs(lhs.distance - parameters.expectedDistance)
            let rhsError = abs(rhs.distance - parameters.expectedDistance)
            if lhsError == rhsError { return lhs.distance < rhs.distance }
            return lhsError < rhsError
        }
        guard let best = ranked.first else { return nil }
        let margin = computeLikelihoodMargin(ranked: ranked, parameters: parameters)
        return makeTransitionResult(best: best, ranked: ranked, likelihoodMargin: margin, parameters: parameters)
    }

    private mutating func collectNodePathOptions(
        from start: TrailMatcherCandidate,
        to end: TrailMatcherCandidate,
        startEdge: TrailGraphEdge,
        endEdge: TrailGraphEdge,
        parameters: TrailMatcherTransitionParameters
    ) -> [PathOption] {
        let startEndpoints = [
            Endpoint(nodeID: startEdge.fromNodeID, cost: start.offsetMeters),
            Endpoint(
                nodeID: startEdge.toNodeID,
                cost: startEdge.lengthMeters - start.offsetMeters
            ),
        ]
        let endEndpoints = [
            Endpoint(nodeID: endEdge.fromNodeID, cost: end.offsetMeters),
            Endpoint(
                nodeID: endEdge.toNodeID,
                cost: endEdge.lengthMeters - end.offsetMeters
            ),
        ]
        let optionLimit = parameters.isSparse ? 5 : 1
        var options: [PathOption] = []
        for startEndpoint in startEndpoints {
            for endEndpoint in endEndpoints {
                let available = parameters.maximumDistance
                    - startEndpoint.cost - endEndpoint.cost
                guard available >= 0 else { continue }
                for path in pathOptions(
                    from: startEndpoint.nodeID,
                    to: endEndpoint.nodeID,
                    maximumDistance: available,
                    limit: optionLimit
                ) {
                    var coordinates = [start.projectedCoordinate]
                    coordinates.append(
                        contentsOf: path.nodes.compactMap { nodes[$0]?.coordinate }
                    )
                    coordinates.append(end.projectedCoordinate)
                    let names = (
                        [startEdge.displayName]
                            + path.edgeIndices.map { edges[$0].displayName }
                            + [endEdge.displayName]
                    ).compactMap(\.self)
                    options.append(
                        PathOption(
                            distance: startEndpoint.cost + path.distance + endEndpoint.cost,
                            coordinates: deduplicated(coordinates),
                            signature: pathSignature(
                                start: start,
                                startEndpoint: startEndpoint,
                                path: path,
                                end: end,
                                endEndpoint: endEndpoint,
                                parameters: parameters
                            ),
                            trailNames: OrderedSet(names).elements
                        )
                    )
                }
            }
        }
        return options
    }

    private func computeLikelihoodMargin(
        ranked: [PathOption],
        parameters: TrailMatcherTransitionParameters
    ) -> Double {
        guard parameters.isSparse, ranked.count > 1,
              let best = ranked.first else { return .infinity }
        let bestError = abs(best.distance - parameters.expectedDistance)
        let nextError = abs(ranked[1].distance - parameters.expectedDistance)
        let similarlyLong = !parameters.hasDistanceEvidence
            && abs(ranked[1].distance - best.distance)
                <= max(ranked[1].distance, best.distance) * Self.similarityThresholdFraction
        return similarlyLong
            ? 0
            : max(0, (nextError - bestError) / parameters.beta)
    }

    private func makeTransitionResult(
        best: PathOption,
        ranked: [PathOption],
        likelihoodMargin: Double,
        parameters: TrailMatcherTransitionParameters
    ) -> TrailMatcherTransition {
        let alternatives: [TrailMatcherTransitionAlternative] = parameters.isSparse
            ? ranked.prefix(2).map { alt in
                TrailMatcherTransitionAlternative(
                    distanceMeters: alt.distance,
                    coordinates: alt.coordinates,
                    trailNames: alt.trailNames.sorted()
                )
            }
            : []
        return TrailMatcherTransition(
            distanceMeters: best.distance,
            coordinates: best.coordinates,
            likelihoodMargin: likelihoodMargin,
            trailNames: best.trailNames,
            alternatives: alternatives
        )
    }

    func deduplicated(
        _ coordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates {
            guard let previous = result.last else {
                result.append(coordinate)
                continue
            }
            if RouteGeometry.distanceMeters(from: previous, to: coordinate)
                > TrailMatcher.minimumCoordinateDistanceMeters {
                result.append(coordinate)
            }
        }
        return result
    }

    func pathSignature(
        start: TrailMatcherCandidate,
        startEndpoint: Endpoint,
        path: NodePath,
        end: TrailMatcherCandidate,
        endEndpoint: Endpoint,
        parameters: TrailMatcherTransitionParameters
    ) -> [Traversal] {
        var traversals: [Traversal] = []
        traversals.reserveCapacity(path.edgeIndices.count + 2)
        if startEndpoint.cost > parameters.startEndpointTolerance {
            traversals.append(
                Traversal(
                    edgeIndex: start.edgeIndex,
                    isForward: startEndpoint.nodeID == edges[start.edgeIndex].toNodeID
                )
            )
        }
        for (edgeIndex, node) in zip(path.edgeIndices, path.nodes) {
            traversals.append(
                Traversal(
                    edgeIndex: edgeIndex,
                    isForward: node == edges[edgeIndex].fromNodeID
                )
            )
        }
        if endEndpoint.cost > parameters.endEndpointTolerance {
            traversals.append(
                Traversal(
                    edgeIndex: end.edgeIndex,
                    isForward: endEndpoint.nodeID == edges[end.edgeIndex].fromNodeID
                )
            )
        }
        return traversals
    }
}
