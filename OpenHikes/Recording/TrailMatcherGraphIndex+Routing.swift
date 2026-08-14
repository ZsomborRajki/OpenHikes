//
//  TrailMatcherGraphIndex+Routing.swift
//  OpenHikes
//
//  Yen's k-shortest-paths and Dijkstra routing on the trail graph.
//

import Foundation
import HeapModule

nonisolated extension TrailMatcherGraphIndex {
    struct NodePath {
        let nodes: [Int64]
        let edgeIndices: [Int]
        let distance: Double
    }

    struct RankedPath: Comparable {
        let path: NodePath

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.path.distance == rhs.path.distance
                ? lhs.path.edgeIndices.lexicographicallyPrecedes(
                    rhs.path.edgeIndices
                )
                : lhs.path.distance < rhs.path.distance
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.path.distance == rhs.path.distance
                && lhs.path.edgeIndices == rhs.path.edgeIndices
        }
    }

    struct NodePair: Hashable {
        let lower: Int64
        let upper: Int64

        init(_ first: Int64, _ second: Int64) {
            lower = min(first, second)
            upper = max(first, second)
        }
    }

    struct HeapEntry: Comparable {
        let distance: Double
        let nodeID: Int64

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.distance == rhs.distance
                ? lhs.nodeID < rhs.nodeID
                : lhs.distance < rhs.distance
        }
    }
}

nonisolated extension TrailMatcherGraphIndex {
    mutating func pathOptions(
        from start: Int64,
        to end: Int64,
        maximumDistance: Double,
        limit: Int
    ) -> [NodePath] {
        guard limit > 0,
              let first = shortestPath(
                from: start,
                to: end,
                maximumDistance: maximumDistance,
                bannedNodes: [],
                bannedEdges: []
              )
        else {
            return []
        }
        guard limit > 1, first.nodes.count > 1 else {
            return [first]
        }
        var accepted = [first]
        var candidateHeap = Heap<RankedPath>()
        var seenSignatures: Set<[Int]> = [first.edgeIndices]
        while accepted.count < limit {
            yenNextIteration(
                lastAccepted: accepted[accepted.count - 1],
                to: end,
                maximumDistance: maximumDistance,
                accepted: accepted,
                seenSignatures: &seenSignatures,
                candidateHeap: &candidateHeap
            )
            guard let next = candidateHeap.popMin() else { break }
            accepted.append(next.path)
        }
        return accepted
    }

    mutating func yenNextIteration(
        lastAccepted previous: NodePath,
        to end: Int64,
        maximumDistance: Double,
        accepted: [NodePath],
        seenSignatures: inout Set<[Int]>,
        candidateHeap: inout Heap<RankedPath>
    ) {
        for spurIndex in 0..<(previous.nodes.count - 1) {
            let rootNodes = Array(previous.nodes[0...spurIndex])
            let rootEdges = Array(previous.edgeIndices.prefix(spurIndex))
            let rootDistance = rootEdges.reduce(0.0) { sum, edgeIdx in
                sum + edges[edgeIdx].lengthMeters
            }
            guard rootDistance <= maximumDistance else { continue }
            var bannedEdges = Set<Int>()
            for path in accepted
            where path.nodes.count > spurIndex
                && Array(path.nodes[0...spurIndex]) == rootNodes {
                if path.edgeIndices.indices.contains(spurIndex) {
                    bannedEdges.insert(path.edgeIndices[spurIndex])
                }
            }
            let bannedNodes = Set(rootNodes.dropLast())
            guard let spur = shortestPath(
                from: rootNodes[rootNodes.count - 1],
                to: end,
                maximumDistance: maximumDistance - rootDistance,
                bannedNodes: bannedNodes,
                bannedEdges: bannedEdges
            ) else {
                continue
            }
            let pathNodes = Array(rootNodes.dropLast()) + spur.nodes
            guard Set(pathNodes).count == pathNodes.count else { continue }
            let edgeIndices = rootEdges + spur.edgeIndices
            guard seenSignatures.insert(edgeIndices).inserted else {
                continue
            }
            candidateHeap.insert(
                RankedPath(
                    path: NodePath(
                        nodes: pathNodes,
                        edgeIndices: edgeIndices,
                        distance: rootDistance + spur.distance
                    )
                )
            )
        }
    }

    mutating func shortestPath(
        from start: Int64,
        to end: Int64,
        maximumDistance: Double,
        bannedNodes: Set<Int64>,
        bannedEdges: Set<Int>
    ) -> NodePath? {
        guard nodes[start] != nil, nodes[end] != nil,
              !bannedNodes.contains(start),
              !bannedNodes.contains(end)
        else {
            return nil
        }
        if start == end {
            return NodePath(nodes: [start], edgeIndices: [], distance: 0)
        }
        let mayUseCache = bannedNodes.isEmpty && bannedEdges.isEmpty
        let cacheKey = NodePair(start, end)
        if mayUseCache, let cached = shortestPathCache[cacheKey] {
            guard cached.distance <= maximumDistance else {
                return nil
            }
            if cached.nodes.first == start {
                return cached
            }
            return NodePath(
                nodes: Array(cached.nodes.reversed()),
                edgeIndices: Array(cached.edgeIndices.reversed()),
                distance: cached.distance
            )
        }
        guard let (distance, previous) = dijkstra(
            from: start,
            to: end,
            maximumDistance: maximumDistance,
            bannedNodes: bannedNodes,
            bannedEdges: bannedEdges
        ) else {
            return nil
        }
        guard let path = reconstructPath(
            from: end,
            to: start,
            previous: previous,
            distance: distance
        ) else {
            return nil
        }
        if mayUseCache {
            shortestPathCache[cacheKey] = path
        }
        return path
    }

    func dijkstra(
        from start: Int64,
        to end: Int64,
        maximumDistance: Double,
        bannedNodes: Set<Int64>,
        bannedEdges: Set<Int>
    ) -> (distance: Double, previous: [Int64: (nodeID: Int64, edgeIndex: Int)])? {
        var distances: [Int64: Double] = [start: 0]
        var previous: [Int64: (nodeID: Int64, edgeIndex: Int)] = [:]
        var frontier = Heap<HeapEntry>()
        frontier.insert(HeapEntry(distance: 0, nodeID: start))
        while let current = frontier.popMin() {
            guard current.distance == distances[current.nodeID],
                  current.distance <= maximumDistance
            else {
                continue
            }
            if current.nodeID == end { break }
            for neighbor in adjacency[current.nodeID] ?? []
            where !bannedNodes.contains(neighbor.nodeID)
                && !bannedEdges.contains(neighbor.edgeIndex) {
                let dist = current.distance + neighbor.distance
                guard dist <= maximumDistance,
                      dist < distances[neighbor.nodeID, default: .infinity]
                else {
                    continue
                }
                distances[neighbor.nodeID] = dist
                previous[neighbor.nodeID] = (current.nodeID, neighbor.edgeIndex)
                frontier.insert(HeapEntry(distance: dist, nodeID: neighbor.nodeID))
            }
        }
        guard let distance = distances[end] else {
            return nil
        }
        return (distance, previous)
    }

    func reconstructPath(
        from end: Int64,
        to start: Int64,
        previous: [Int64: (nodeID: Int64, edgeIndex: Int)],
        distance: Double
    ) -> NodePath? {
        var pathNodes = [end]
        var pathEdges: [Int] = []
        var cursor = end
        while cursor != start {
            guard let step = previous[cursor] else {
                return nil
            }
            pathEdges.append(step.edgeIndex)
            cursor = step.nodeID
            pathNodes.append(cursor)
        }
        pathNodes.reverse()
        pathEdges.reverse()
        return NodePath(nodes: pathNodes, edgeIndices: pathEdges, distance: distance)
    }
}
