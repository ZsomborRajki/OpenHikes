//
//  TrailMatcher.swift
//  OpenTrails
//
//  On-device HMM map matching over a cached OSM walking graph. Low-confidence
//  legs remain GPS geometry; matching is allowed to abstain.
//

import CoreLocation
import Foundation

nonisolated struct TrailMatchAlternative: Equatable, Sendable {
    let id: Int
    let points: [RecordingPoint]
    let distanceMeters: Double
    let trailNames: [String]
}

nonisolated struct TrailMatchAmbiguity: Equatable, Identifiable, Sendable {
    let id: Int
    let gpsPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
}

nonisolated enum TrailAmbiguityChoice: Equatable, Sendable {
    case gps
    case alternative(Int)
}

nonisolated struct TrailMatchLeg: Sendable {
    let index: Int
    let defaultPoints: [RecordingPoint]
    let alternatives: [TrailMatchAlternative]
}

nonisolated struct TrailMatchResult: Sendable {
    let points: [RecordingPoint]
    let matchedLegCount: Int
    let ambiguousLegCount: Int
    let matchedTrailName: String?
    let currentTrailName: String?
    let didMoveRoute: Bool
    let ambiguities: [TrailMatchAmbiguity]
    let legs: [TrailMatchLeg]

    func points(
        resolving choices: [Int: TrailAmbiguityChoice]
    ) -> [RecordingPoint] {
        guard !legs.isEmpty else { return points }
        var output: [RecordingPoint] = []
        for leg in legs {
            let selected: [RecordingPoint]
            switch choices[leg.index] ?? .gps {
            case .gps:
                selected = leg.defaultPoints
            case .alternative(let alternativeID):
                selected = leg.alternatives.first {
                    $0.id == alternativeID
                }?.points ?? leg.defaultPoints
            }
            if output.isEmpty {
                output.append(contentsOf: selected)
            } else if let previous = output.last,
                      let first = selected.first,
                      RouteGeometry.distanceMeters(
                          from: previous.coordinate,
                          to: first.coordinate
                      ) <= 0.05 {
                output.append(contentsOf: selected.dropFirst())
            } else {
                output.append(contentsOf: selected)
            }
        }
        return output
    }
}

nonisolated enum TrailMatcher {
    private static let maximumCandidatesPerFix = 8
    private static let minimumSigmaMeters = 4.0
    private static let confidenceRatio = 1.15
    private static let confidenceLogMargin = log(confidenceRatio)
    private static let sparseInterval: TimeInterval = 90
    private static let sparseDisplacement: CLLocationDistance = 200

    static func needsDistanceEvidence(
        from previous: RecordingPoint,
        to current: RecordingPoint
    ) -> Bool {
        guard !current.flags.contains(.resumed) else { return false }
        return current.timestamp.timeIntervalSince(previous.timestamp)
                > sparseInterval
            || RouteGeometry.distanceMeters(
                from: previous.coordinate,
                to: current.coordinate
            ) > sparseDisplacement
    }

    static func match(
        points: [RecordingPoint],
        graph: TrailGraph,
        gapDistances: [Int: Double] = [:]
    ) -> TrailMatchResult {
        guard points.count > 1, !graph.isEmpty else {
            return TrailMatchResult(
                points: points,
                matchedLegCount: 0,
                ambiguousLegCount: 0,
                matchedTrailName: nil,
                currentTrailName: nil,
                didMoveRoute: false,
                ambiguities: [],
                legs: []
            )
        }

        var index = GraphIndex(graph: graph)
        let candidates = points.map { index.candidates(for: $0) }
        var selected = [Candidate?](repeating: nil, count: points.count)
        var scoreMargins = [Double](
            repeating: -.infinity,
            count: points.count
        )
        var blockIDs = [Int?](repeating: nil, count: points.count)

        var blockID = 0
        var start = 0
        while start < points.count {
            while start < points.count, candidates[start].isEmpty {
                start += 1
            }
            guard start < points.count else { break }

            var scoreHistory = [
                candidates[start].map {
                    emissionLogProbability($0, for: points[start])
                }
            ]
            var backHistory: [[Int]] = []
            var end = start

            while end + 1 < points.count {
                let next = end + 1
                guard !points[next].flags.contains(.resumed),
                      !candidates[next].isEmpty
                else {
                    break
                }

                let previousScores = scoreHistory[scoreHistory.count - 1]
                var nextScores = [Double](
                    repeating: -.infinity,
                    count: candidates[next].count
                )
                var nextBack = [Int](
                    repeating: -1,
                    count: candidates[next].count
                )
                let parameters = transitionParameters(
                    from: points[end],
                    to: points[next],
                    evidenceDistance: gapDistances[next]
                )

                for currentIndex in candidates[next].indices {
                    for previousIndex in candidates[end].indices {
                        guard previousScores[previousIndex].isFinite,
                              let transition = index.transition(
                                from: candidates[end][previousIndex],
                                to: candidates[next][currentIndex],
                                parameters: parameters
                              )
                        else {
                            continue
                        }
                        let score = previousScores[previousIndex]
                            + transitionLogProbability(
                                transition.distanceMeters,
                                parameters: parameters
                            )
                            + emissionLogProbability(
                                candidates[next][currentIndex],
                                for: points[next]
                            )
                        if score > nextScores[currentIndex] {
                            nextScores[currentIndex] = score
                            nextBack[currentIndex] = previousIndex
                        }
                    }
                }

                guard nextScores.contains(where: \.isFinite) else { break }
                scoreHistory.append(nextScores)
                backHistory.append(nextBack)
                end = next
            }

            guard let bestFinal = bestIndex(
                in: scoreHistory[scoreHistory.count - 1]
            ) else {
                start += 1
                continue
            }
            var chosen = bestFinal
            for localIndex in stride(
                from: scoreHistory.count - 1,
                through: 0,
                by: -1
            ) {
                let pointIndex = start + localIndex
                selected[pointIndex] = candidates[pointIndex][chosen]
                scoreMargins[pointIndex] = margin(
                    for: chosen,
                    in: scoreHistory[localIndex],
                    candidates: candidates[pointIndex]
                )
                blockIDs[pointIndex] = blockID
                if localIndex > 0 {
                    chosen = backHistory[localIndex - 1][chosen]
                }
            }

            blockID += 1
            start = end + 1
        }

        struct Leg {
            let transition: Transition?
            let isConfident: Bool
            let isSparse: Bool
        }
        var legs: [Leg] = []
        legs.reserveCapacity(points.count - 1)
        var matchedLegCount = 0
        var ambiguousLegCount = 0
        var trailNameCounts: [String: Int] = [:]
        var didMoveRoute = false

        for indexInPoints in 1..<points.count {
            let previousIndex = indexInPoints - 1
            guard let previous = selected[previousIndex],
                  let current = selected[indexInPoints],
                  blockIDs[previousIndex] == blockIDs[indexInPoints],
                  !points[indexInPoints].flags.contains(.resumed)
            else {
                legs.append(
                    Leg(
                        transition: nil,
                        isConfident: false,
                        isSparse: false
                    )
                )
                continue
            }
            let parameters = transitionParameters(
                from: points[previousIndex],
                to: points[indexInPoints],
                evidenceDistance: gapDistances[indexInPoints]
            )
            guard let transition = index.transition(
                from: previous,
                to: current,
                parameters: parameters
            ) else {
                legs.append(
                    Leg(
                        transition: nil,
                        isConfident: false,
                        isSparse: parameters.isSparse
                    )
                )
                continue
            }

            let candidateSequenceIsConfident =
                scoreMargins[previousIndex] >= confidenceLogMargin
                && scoreMargins[indexInPoints] >= confidenceLogMargin
            let confident = candidateSequenceIsConfident
                && (
                    !parameters.isSparse
                    || transition.likelihoodMargin >= confidenceLogMargin
                )
            legs.append(
                Leg(
                    transition: transition,
                    isConfident: confident,
                    isSparse: parameters.isSparse
                )
            )
            if confident {
                matchedLegCount += 1
                if previous.offRouteMeters > 1 || current.offRouteMeters > 1
                    || transition.coordinates.count > 2 {
                    didMoveRoute = true
                }
                for name in transition.trailNames {
                    trailNameCounts[name, default: 0] += 1
                }
            } else if parameters.isSparse {
                ambiguousLegCount += 1
            }
        }

        var usesMatchedAnchor = [Bool](repeating: false, count: points.count)
        for indexInLegs in legs.indices where legs[indexInLegs].isConfident {
            usesMatchedAnchor[indexInLegs] = true
            usesMatchedAnchor[indexInLegs + 1] = true
        }

        let anchors = points.indices.map { pointIndex -> RecordingPoint in
            guard usesMatchedAnchor[pointIndex],
                  let candidate = selected[pointIndex]
            else {
                return points[pointIndex]
            }
            return point(
                points[pointIndex],
                movedTo: candidate.projectedCoordinate
            )
        }

        var output: [RecordingPoint] = []
        var matchLegs: [TrailMatchLeg] = []
        var ambiguities: [TrailMatchAmbiguity] = []
        for indexInPoints in 1..<points.count {
            let previousIndex = indexInPoints - 1
            let coordinates: [CLLocationCoordinate2D]
            if legs[previousIndex].isConfident,
               let transition = legs[previousIndex].transition {
                coordinates = transition.coordinates
            } else {
                coordinates = [
                    anchors[previousIndex].coordinate,
                    anchors[indexInPoints].coordinate
                ]
            }
            let segment = recordingPoints(
                along: coordinates,
                from: anchors[previousIndex],
                to: anchors[indexInPoints]
            )
            let alternatives: [TrailMatchAlternative]
            if !legs[previousIndex].isConfident,
               legs[previousIndex].isSparse,
               let transition = legs[previousIndex].transition {
                alternatives = transition.alternatives.enumerated().map {
                    alternativeIndex, alternative in
                    TrailMatchAlternative(
                        id: alternativeIndex,
                        points: recordingPoints(
                            along: alternative.coordinates,
                            from: anchors[previousIndex],
                            to: anchors[indexInPoints]
                        ),
                        distanceMeters: alternative.distanceMeters,
                        trailNames: alternative.trailNames
                    )
                }
            } else {
                alternatives = []
            }
            matchLegs.append(
                TrailMatchLeg(
                    index: previousIndex,
                    defaultPoints: segment,
                    alternatives: alternatives
                )
            )
            if !alternatives.isEmpty {
                ambiguities.append(
                    TrailMatchAmbiguity(
                        id: previousIndex,
                        gpsPoints: segment,
                        alternatives: alternatives
                    )
                )
            }
            if output.isEmpty {
                output.append(contentsOf: segment)
            } else {
                output.append(contentsOf: segment.dropFirst())
            }
        }

        let matchedTrailName = trailNameCounts.max {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }?.key
        let currentTrailName: String?
        if let last = legs.last,
           last.isConfident,
           let transition = last.transition {
            currentTrailName = transition.trailNames.sorted().first
        } else {
            currentTrailName = nil
        }
        return TrailMatchResult(
            points: output,
            matchedLegCount: matchedLegCount,
            ambiguousLegCount: ambiguousLegCount,
            matchedTrailName: matchedTrailName,
            currentTrailName: currentTrailName,
            didMoveRoute: didMoveRoute,
            ambiguities: ambiguities,
            legs: matchLegs
        )
    }

    private struct TransitionParameters {
        let expectedDistance: Double
        let maximumDistance: Double
        let beta: Double
        let isSparse: Bool
        let hasDistanceEvidence: Bool
        let startEndpointTolerance: Double
        let endEndpointTolerance: Double
    }

    private static func transitionParameters(
        from previous: RecordingPoint,
        to current: RecordingPoint,
        evidenceDistance: Double?
    ) -> TransitionParameters {
        let interval = max(
            1,
            current.timestamp.timeIntervalSince(previous.timestamp)
        )
        let direct = RouteGeometry.distanceMeters(
            from: previous.coordinate,
            to: current.coordinate
        )
        let sparse = interval > sparseInterval
            || direct > sparseDisplacement
        let expected = max(0, evidenceDistance ?? direct)
        let maximumSpeed = sparse ? 2.5 : 3.5
        let accuracyAllowance = previous.horizontalAccuracy
            + current.horizontalAccuracy
        let maximumDistance = max(
            75,
            max(
                interval * maximumSpeed + accuracyAllowance,
                evidenceDistance.map {
                    $0 * 1.2 + accuracyAllowance
                } ?? 0
            )
        )
        return TransitionParameters(
            expectedDistance: expected,
            maximumDistance: maximumDistance,
            beta: max(10, min(180, interval * 0.5)),
            isSparse: sparse,
            hasDistanceEvidence: evidenceDistance != nil,
            startEndpointTolerance: max(
                minimumSigmaMeters,
                previous.horizontalAccuracy
            ),
            endEndpointTolerance: max(
                minimumSigmaMeters,
                current.horizontalAccuracy
            )
        )
    }

    private static func emissionLogProbability(
        _ candidate: Candidate,
        for point: RecordingPoint
    ) -> Double {
        let sourceWeight = point.flags.contains(.widgetSourced) ? 1.5 : 1
        let sigma = max(
            minimumSigmaMeters,
            point.horizontalAccuracy * sourceWeight
        )
        return -(candidate.offRouteMeters * candidate.offRouteMeters)
            / (2 * sigma * sigma)
    }

    private static func transitionLogProbability(
        _ routeDistance: Double,
        parameters: TransitionParameters
    ) -> Double {
        -abs(routeDistance - parameters.expectedDistance) / parameters.beta
    }

    private static func bestIndex(in scores: [Double]) -> Int? {
        scores.indices
            .filter { scores[$0].isFinite }
            .max { scores[$0] < scores[$1] }
    }

    private static func margin(
        for selectedIndex: Int,
        in scores: [Double],
        candidates: [Candidate]
    ) -> Double {
        let selected = scores[selectedIndex]
        let selectedCoordinate = candidates[selectedIndex]
            .projectedCoordinate
        let runnerUp = scores.indices
            .filter {
                $0 != selectedIndex
                    && scores[$0].isFinite
                    && RouteGeometry.distanceMeters(
                        from: candidates[$0].projectedCoordinate,
                        to: selectedCoordinate
                    ) > 1
            }
            .map { scores[$0] }
            .max()
        return runnerUp.map { selected - $0 } ?? .infinity
    }

    private static func point(
        _ source: RecordingPoint,
        movedTo coordinate: CLLocationCoordinate2D
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timestamp: source.timestamp,
            elevation: source.elevation,
            horizontalAccuracy: source.horizontalAccuracy,
            course: source.course,
            speed: source.speed,
            flags: source.flags
        )
    }

    private static func recordingPoints(
        along rawCoordinates: [CLLocationCoordinate2D],
        from start: RecordingPoint,
        to end: RecordingPoint
    ) -> [RecordingPoint] {
        var coordinates: [CLLocationCoordinate2D] = []
        for coordinate in [start.coordinate]
            + rawCoordinates
            + [end.coordinate] {
            guard let previous = coordinates.last else {
                coordinates.append(coordinate)
                continue
            }
            if RouteGeometry.distanceMeters(
                from: previous,
                to: coordinate
            ) > 0.05 {
                coordinates.append(coordinate)
            }
        }
        if coordinates.count < 2 {
            coordinates = [start.coordinate, end.coordinate]
        }

        var distances = [0.0]
        for index in 1..<coordinates.count {
            distances.append(
                distances[index - 1]
                    + RouteGeometry.distanceMeters(
                        from: coordinates[index - 1],
                        to: coordinates[index]
                    )
            )
        }
        let total = distances.last ?? 0
        let duration = end.timestamp.timeIntervalSince(start.timestamp)
        let carriesNonPedestrianMotion =
            start.flags.contains(.nonPedestrian)
            || end.flags.contains(.nonPedestrian)

        return coordinates.indices.map { index in
            let fraction = total > 0
                ? distances[index] / total
                : Double(index) / Double(max(1, coordinates.count - 1))
            let elevation: Double?
            if let startElevation = start.elevation,
               let endElevation = end.elevation {
                elevation = startElevation
                    + (endElevation - startElevation) * fraction
            } else if index == 0 {
                elevation = start.elevation
            } else if index == coordinates.count - 1 {
                elevation = end.elevation
            } else {
                elevation = nil
            }

            return RecordingPoint(
                latitude: coordinates[index].latitude,
                longitude: coordinates[index].longitude,
                timestamp: start.timestamp.addingTimeInterval(
                    duration * fraction
                ),
                elevation: elevation,
                horizontalAccuracy: start.horizontalAccuracy
                    + (end.horizontalAccuracy - start.horizontalAccuracy)
                        * fraction,
                course: index == 0
                    ? start.course
                    : (index == coordinates.count - 1 ? end.course : nil),
                speed: index == 0
                    ? start.speed
                    : (index == coordinates.count - 1 ? end.speed : nil),
                flags: {
                    var flags: RecordingPointFlags = carriesNonPedestrianMotion
                        ? [.nonPedestrian]
                        : []
                    if index == 0 {
                        flags.formUnion(start.flags)
                    } else if index == coordinates.count - 1 {
                        flags.formUnion(end.flags)
                    }
                    return flags
                }()
            )
        }
    }

    private struct Candidate {
        let edgeIndex: Int
        let projectedCoordinate: CLLocationCoordinate2D
        let offsetMeters: Double
        let offRouteMeters: Double
    }

    private struct Transition {
        let distanceMeters: Double
        let coordinates: [CLLocationCoordinate2D]
        let likelihoodMargin: Double
        let trailNames: [String]
        let alternatives: [TransitionAlternative]
    }

    private struct TransitionAlternative {
        let distanceMeters: Double
        let coordinates: [CLLocationCoordinate2D]
        let trailNames: [String]
    }

    private struct GraphIndex {
        private struct Adjacency {
            let nodeID: Int64
            let edgeIndex: Int
            let distance: Double
        }

        private struct NodePath {
            let nodes: [Int64]
            let edgeIndices: [Int]
            let distance: Double
        }

        private struct PathOption {
            let distance: Double
            let coordinates: [CLLocationCoordinate2D]
            let signature: String
            let trailNames: [String]
        }

        private struct Endpoint {
            let nodeID: Int64
            let cost: Double
        }

        private struct HeapEntry {
            let distance: Double
            let nodeID: Int64
        }

        private struct MinHeap {
            private var values: [HeapEntry] = []

            var isEmpty: Bool { values.isEmpty }

            mutating func push(_ entry: HeapEntry) {
                values.append(entry)
                var index = values.count - 1
                while index > 0 {
                    let parent = (index - 1) / 2
                    guard values[index].distance < values[parent].distance
                    else {
                        break
                    }
                    values.swapAt(index, parent)
                    index = parent
                }
            }

            mutating func pop() -> HeapEntry? {
                guard !values.isEmpty else { return nil }
                if values.count == 1 { return values.removeLast() }
                let result = values[0]
                values[0] = values.removeLast()
                var index = 0
                while true {
                    let left = index * 2 + 1
                    let right = left + 1
                    var smallest = index
                    if left < values.count,
                       values[left].distance < values[smallest].distance {
                        smallest = left
                    }
                    if right < values.count,
                       values[right].distance < values[smallest].distance {
                        smallest = right
                    }
                    guard smallest != index else { break }
                    values.swapAt(index, smallest)
                    index = smallest
                }
                return result
            }
        }

        private let nodes: [Int64: TrailGraphNode]
        private let edges: [TrailGraphEdge]
        private let adjacency: [Int64: [Adjacency]]
        private var shortestPathCache: [String: NodePath] = [:]

        init(graph: TrailGraph) {
            let nodeMap = Dictionary(
                uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
            )
            let validEdges = graph.edges.filter {
                nodeMap[$0.fromNodeID] != nil
                    && nodeMap[$0.toNodeID] != nil
            }
            nodes = nodeMap
            edges = validEdges
            var adjacency: [Int64: [Adjacency]] = [:]
            for (edgeIndex, edge) in validEdges.enumerated() {
                adjacency[edge.fromNodeID, default: []].append(
                    Adjacency(
                        nodeID: edge.toNodeID,
                        edgeIndex: edgeIndex,
                        distance: edge.lengthMeters
                    )
                )
                adjacency[edge.toNodeID, default: []].append(
                    Adjacency(
                        nodeID: edge.fromNodeID,
                        edgeIndex: edgeIndex,
                        distance: edge.lengthMeters
                    )
                )
            }
            self.adjacency = adjacency
        }

        func candidates(for point: RecordingPoint) -> [Candidate] {
            let radius = max(50, point.horizontalAccuracy * 3)
            var candidates: [Candidate] = []
            candidates.reserveCapacity(maximumCandidatesPerFix)

            for (edgeIndex, edge) in edges.enumerated() {
                guard let start = nodes[edge.fromNodeID]?.coordinate,
                      let end = nodes[edge.toNodeID]?.coordinate
                else {
                    continue
                }
                let startOffset = RouteGeometry.localOffset(
                    from: point.coordinate,
                    to: start
                )
                let endOffset = RouteGeometry.localOffset(
                    from: point.coordinate,
                    to: end
                )
                let dx = endOffset.x - startOffset.x
                let dy = endOffset.y - startOffset.y
                let lengthSquared = dx * dx + dy * dy
                let fraction = lengthSquared > 0
                    ? min(
                        max(
                            -(startOffset.x * dx + startOffset.y * dy)
                                / lengthSquared,
                            0
                        ),
                        1
                    )
                    : 0
                let projectedX = startOffset.x + fraction * dx
                let projectedY = startOffset.y + fraction * dy
                let offRoute = hypot(projectedX, projectedY)
                guard offRoute <= radius else { continue }
                candidates.append(
                    Candidate(
                        edgeIndex: edgeIndex,
                        projectedCoordinate: RouteGeometry.interpolate(
                            from: start,
                            to: end,
                            fraction: fraction
                        ),
                        offsetMeters: edge.lengthMeters * fraction,
                        offRouteMeters: offRoute
                    )
                )
            }

            return candidates
                .sorted { $0.offRouteMeters < $1.offRouteMeters }
                .prefix(maximumCandidatesPerFix)
                .map { $0 }
        }

        mutating func transition(
            from start: Candidate,
            to end: Candidate,
            parameters: TransitionParameters
        ) -> Transition? {
            var options: [PathOption] = []
            let startEdge = edges[start.edgeIndex]
            let endEdge = edges[end.edgeIndex]

            if start.edgeIndex == end.edgeIndex {
                let coordinates = [
                    start.projectedCoordinate,
                    end.projectedCoordinate
                ]
                options.append(
                    PathOption(
                        distance: abs(
                            end.offsetMeters - start.offsetMeters
                        ),
                        coordinates: coordinates,
                        signature: traversalToken(
                            edgeIndex: start.edgeIndex,
                            forward: end.offsetMeters
                                >= start.offsetMeters
                        ),
                        trailNames: startEdge.displayName.map { [$0] } ?? []
                    )
                )
            }

            let startEndpoints = [
                Endpoint(
                    nodeID: startEdge.fromNodeID,
                    cost: start.offsetMeters
                ),
                Endpoint(
                    nodeID: startEdge.toNodeID,
                    cost: startEdge.lengthMeters - start.offsetMeters
                )
            ]
            let endEndpoints = [
                Endpoint(
                    nodeID: endEdge.fromNodeID,
                    cost: end.offsetMeters
                ),
                Endpoint(
                    nodeID: endEdge.toNodeID,
                    cost: endEdge.lengthMeters - end.offsetMeters
                )
            ]
            let optionLimit = parameters.isSparse ? 5 : 1

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
                            contentsOf: path.nodes.compactMap {
                                nodes[$0]?.coordinate
                            }
                        )
                        coordinates.append(end.projectedCoordinate)
                        let names = (
                            [startEdge.displayName]
                                + path.edgeIndices.map {
                                    edges[$0].displayName
                                }
                                + [endEdge.displayName]
                        ).compactMap { $0 }
                        let pathCoordinates = deduplicated(coordinates)
                        options.append(
                            PathOption(
                                distance: startEndpoint.cost
                                    + path.distance + endEndpoint.cost,
                                coordinates: pathCoordinates,
                                signature: pathSignature(
                                    start: start,
                                    startEndpoint: startEndpoint,
                                    path: path,
                                    end: end,
                                    endEndpoint: endEndpoint,
                                    parameters: parameters
                                ),
                                trailNames: Array(Set(names))
                            )
                        )
                    }
                }
            }

            var unique: [String: PathOption] = [:]
            for option in options where option.distance
                <= parameters.maximumDistance {
                if let existing = unique[option.signature] {
                    if option.distance < existing.distance {
                        unique[option.signature] = option
                    }
                } else {
                    unique[option.signature] = option
                }
            }
            let ranked = unique.values.sorted {
                let lhsError = abs(
                    $0.distance - parameters.expectedDistance
                )
                let rhsError = abs(
                    $1.distance - parameters.expectedDistance
                )
                if lhsError == rhsError { return $0.distance < $1.distance }
                return lhsError < rhsError
            }
            guard let best = ranked.first else { return nil }
            let likelihoodMargin: Double
            if parameters.isSparse, ranked.count > 1 {
                let bestError = abs(
                    best.distance - parameters.expectedDistance
                )
                let nextError = abs(
                    ranked[1].distance - parameters.expectedDistance
                )
                let similarlyLong = !parameters.hasDistanceEvidence
                    && abs(ranked[1].distance - best.distance)
                        <= max(ranked[1].distance, best.distance) * 0.15
                likelihoodMargin = similarlyLong
                    ? 0
                    : max(
                        0,
                        (nextError - bestError) / parameters.beta
                    )
            } else {
                likelihoodMargin = .infinity
            }
            return Transition(
                distanceMeters: best.distance,
                coordinates: best.coordinates,
                likelihoodMargin: likelihoodMargin,
                trailNames: best.trailNames,
                alternatives: parameters.isSparse
                    ? ranked.prefix(2).map {
                        TransitionAlternative(
                            distanceMeters: $0.distance,
                            coordinates: $0.coordinates,
                            trailNames: $0.trailNames.sorted()
                        )
                    }
                    : []
            )
        }

        private mutating func pathOptions(
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
            guard limit > 1, first.nodes.count > 1 else { return [first] }

            var accepted = [first]
            var candidates: [String: NodePath] = [:]
            while accepted.count < limit {
                let previous = accepted[accepted.count - 1]
                for spurIndex in 0..<(previous.nodes.count - 1) {
                    let rootNodes = Array(previous.nodes[0...spurIndex])
                    let rootEdges = Array(previous.edgeIndices.prefix(spurIndex))
                    let rootDistance = rootEdges.reduce(0) {
                        $0 + edges[$1].lengthMeters
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
                    let nodes = Array(rootNodes.dropLast()) + spur.nodes
                    guard Set(nodes).count == nodes.count else { continue }
                    let edgeIndices = rootEdges + spur.edgeIndices
                    let path = NodePath(
                        nodes: nodes,
                        edgeIndices: edgeIndices,
                        distance: rootDistance + spur.distance
                    )
                    let signature = edgeIndices.map(String.init)
                        .joined(separator: ",")
                    if !accepted.contains(where: {
                        $0.edgeIndices == path.edgeIndices
                    }) {
                        candidates[signature] = path
                    }
                }

                guard let next = candidates.values.min(by: {
                    $0.distance < $1.distance
                }) else {
                    break
                }
                let signature = next.edgeIndices.map(String.init)
                    .joined(separator: ",")
                candidates[signature] = nil
                accepted.append(next)
            }
            return accepted
        }

        private mutating func shortestPath(
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
            let cacheKey = start < end
                ? "\(start)/\(end)"
                : "\(end)/\(start)"
            if mayUseCache, let cached = shortestPathCache[cacheKey] {
                guard cached.distance <= maximumDistance else { return nil }
                if cached.nodes.first == start { return cached }
                return NodePath(
                    nodes: Array(cached.nodes.reversed()),
                    edgeIndices: Array(cached.edgeIndices.reversed()),
                    distance: cached.distance
                )
            }

            var distances: [Int64: Double] = [start: 0]
            var previous: [Int64: (nodeID: Int64, edgeIndex: Int)] = [:]
            var heap = MinHeap()
            heap.push(HeapEntry(distance: 0, nodeID: start))

            while !heap.isEmpty, let current = heap.pop() {
                guard current.distance == distances[current.nodeID],
                      current.distance <= maximumDistance
                else {
                    continue
                }
                if current.nodeID == end { break }

                for neighbor in adjacency[current.nodeID] ?? []
                where !bannedNodes.contains(neighbor.nodeID)
                    && !bannedEdges.contains(neighbor.edgeIndex) {
                    let distance = current.distance + neighbor.distance
                    guard distance <= maximumDistance,
                          distance < distances[neighbor.nodeID, default: .infinity]
                    else {
                        continue
                    }
                    distances[neighbor.nodeID] = distance
                    previous[neighbor.nodeID] = (
                        current.nodeID,
                        neighbor.edgeIndex
                    )
                    heap.push(
                        HeapEntry(
                            distance: distance,
                            nodeID: neighbor.nodeID
                        )
                    )
                }
            }

            guard let distance = distances[end] else { return nil }
            var pathNodes = [end]
            var pathEdges: [Int] = []
            var cursor = end
            while cursor != start {
                guard let step = previous[cursor] else { return nil }
                pathEdges.append(step.edgeIndex)
                cursor = step.nodeID
                pathNodes.append(cursor)
            }
            pathNodes.reverse()
            pathEdges.reverse()
            let path = NodePath(
                nodes: pathNodes,
                edgeIndices: pathEdges,
                distance: distance
            )
            if mayUseCache {
                shortestPathCache[cacheKey] = path
            }
            return path
        }

        private func deduplicated(
            _ coordinates: [CLLocationCoordinate2D]
        ) -> [CLLocationCoordinate2D] {
            var result: [CLLocationCoordinate2D] = []
            for coordinate in coordinates {
                guard let previous = result.last else {
                    result.append(coordinate)
                    continue
                }
                if RouteGeometry.distanceMeters(
                    from: previous,
                    to: coordinate
                ) > 0.05 {
                    result.append(coordinate)
                }
            }
            return result
        }

        private func pathSignature(
            start: Candidate,
            startEndpoint: Endpoint,
            path: NodePath,
            end: Candidate,
            endEndpoint: Endpoint,
            parameters: TransitionParameters
        ) -> String {
            var traversals: [String] = []
            if startEndpoint.cost > parameters.startEndpointTolerance {
                traversals.append(
                    traversalToken(
                        edgeIndex: start.edgeIndex,
                        forward: startEndpoint.nodeID
                            == edges[start.edgeIndex].toNodeID
                    )
                )
            }
            for index in path.edgeIndices.indices {
                let edgeIndex = path.edgeIndices[index]
                traversals.append(
                    traversalToken(
                        edgeIndex: edgeIndex,
                        forward: path.nodes[index]
                            == edges[edgeIndex].fromNodeID
                    )
                )
            }
            if endEndpoint.cost > parameters.endEndpointTolerance {
                traversals.append(
                    traversalToken(
                        edgeIndex: end.edgeIndex,
                        forward: endEndpoint.nodeID
                            == edges[end.edgeIndex].fromNodeID
                    )
                )
            }
            return traversals.isEmpty
                ? "stationary"
                : traversals.joined(separator: ",")
        }

        private func traversalToken(
            edgeIndex: Int,
            forward: Bool
        ) -> String {
            "\(forward ? "+" : "-")\(edgeIndex)"
        }
    }
}
