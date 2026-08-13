//
//  TrailMatcher.swift
//  OpenTrails
//
//  On-device HMM map matching over a cached OSM walking graph. Low-confidence
//  legs remain GPS geometry; matching is allowed to abstain.
//

import Algorithms
import CoreLocation
import Foundation
import HeapModule
import OrderedCollections

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
        for (indexInLegs, leg) in legs.enumerated() where leg.isConfident {
            usesMatchedAnchor[indexInLegs] = true
            usesMatchedAnchor[indexInLegs + 1] = true
        }

        let anchors = zip(points, zip(usesMatchedAnchor, selected)).map {
            rawPoint, anchorState -> RecordingPoint in
            let (isAnchored, candidate) = anchorState
            guard isAnchored, let candidate else { return rawPoint }
            return point(rawPoint, movedTo: candidate.projectedCoordinate)
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

        // Running total along the route, one entry per coordinate: the walk
        // starts at zero and each step adds the leg that reached it, so
        // `distances[i]` is how far along the route `coordinates[i]` sits.
        let distances = coordinates.adjacentPairs().reductions(0.0) {
            travelled, leg in
            travelled + RouteGeometry.distanceMeters(from: leg.0, to: leg.1)
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

    /// Ordered by how far the fix is off this edge, with the edge index
    /// breaking ties so a point equidistant from two edges always picks the
    /// same one. ``GraphIndex/candidates(for:)`` keeps only the closest few,
    /// which is what makes the ordering worth defining.
    private struct Candidate: Comparable {
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

        /// A path Yen's algorithm has found but not yet accepted, ordered by
        /// length so the priority queue hands back the next-shortest detour.
        /// The edge list breaks ties, so two equal-length detours are always
        /// accepted in the same order.
        private struct RankedPath: Comparable {
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

        /// One direction of travel along one edge. A transition is identified
        /// by the sequence of these it walks, so this is what makes two
        /// routings between the same pair of candidates comparable.
        private struct Traversal: Hashable {
            let edgeIndex: Int
            let isForward: Bool
        }

        /// The two endpoints of a shortest-path query, normalised so that a
        /// route and its reverse share one cache entry.
        private struct NodePair: Hashable {
            let lower: Int64
            let upper: Int64

            init(_ first: Int64, _ second: Int64) {
                lower = min(first, second)
                upper = max(first, second)
            }
        }

        private struct PathOption {
            let distance: Double
            let coordinates: [CLLocationCoordinate2D]
            let signature: [Traversal]
            let trailNames: [String]
        }

        private struct Endpoint {
            let nodeID: Int64
            let cost: Double
        }

        /// Dijkstra's frontier entry. `Comparable` on distance alone is what
        /// lets ``Heap`` order it; the node ID breaks ties so equal-distance
        /// entries pop in a fixed order rather than one that depends on how
        /// the heap happened to be laid out.
        private struct HeapEntry: Comparable {
            let distance: Double
            let nodeID: Int64

            static func < (lhs: Self, rhs: Self) -> Bool {
                lhs.distance == rhs.distance
                    ? lhs.nodeID < rhs.nodeID
                    : lhs.distance < rhs.distance
            }
        }

        private struct EdgeEndpoints {
            let start: CLLocationCoordinate2D
            let end: CLLocationCoordinate2D
        }

        /// A uniform grid over the graph's edges, so a fix is projected
        /// against the segments near it rather than against every segment in
        /// the region.
        ///
        /// An alpine zoom-12 region holds tens of thousands of segments, and
        /// matching asks for candidates once per fix, so the exhaustive scan
        /// this replaces cost the product of the two: a long hike spent tens
        /// of millions of projections while the walker waited on Stop.
        ///
        /// Cells sit in one equirectangular frame shared by the whole graph.
        /// That frame's scale error grows with the distance being *measured*,
        /// not with the distance from its origin, so across a search radius of
        /// a few hundred metres it stays far below ``marginMeters``.
        private struct EdgeGrid {
            /// Ways are split at every OSM node, so segments run to tens of
            /// metres: this keeps a cell's occupancy low while a typical
            /// query still touches only a handful of cells.
            private static let cellSizeMeters = 200.0
            /// Slack on every query box, absorbing the shared frame's scale
            /// error so the grid can never hide an edge the exhaustive scan
            /// would have found.
            private static let marginMeters = 2.0
            /// Half-lengths above this go on ``alwaysScanned`` instead of
            /// widening every query. A single freakishly long segment would
            /// otherwise decide the search box for the whole graph.
            private static let maximumEdgeReachMeters = 400.0

            private struct Cell: Hashable {
                let x: Int32
                let y: Int32
            }

            private let origin: CLLocationCoordinate2D
            /// Each edge is filed under the one cell holding its midpoint, so
            /// a query visits an edge at most once and the caller never sees
            /// the same candidate twice.
            private let cells: [Cell: [Int]]
            /// How far a bucketed edge can reach from its own midpoint. Every
            /// query box grows by this, which is what lets one cell per edge
            /// still be exhaustive.
            private let reachMeters: Double
            /// Edges too long, or too degenerate, to place — offered to every
            /// query so the exact projection still decides them.
            private let alwaysScanned: [Int]

            init(endpoints: [EdgeEndpoints]) {
                guard let first = endpoints.first else {
                    origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
                    cells = [:]
                    reachMeters = 0
                    alwaysScanned = []
                    return
                }

                let origin = first.start
                var cells: [Cell: [Int]] = [:]
                var alwaysScanned: [Int] = []
                var reach = 0.0

                for (index, endpoint) in endpoints.enumerated() {
                    let start = RouteGeometry.localOffset(
                        from: origin,
                        to: endpoint.start
                    )
                    let end = RouteGeometry.localOffset(
                        from: origin,
                        to: endpoint.end
                    )
                    let midpointX = (start.x + end.x) / 2
                    let midpointY = (start.y + end.y) / 2
                    let halfLength = hypot(end.x - start.x, end.y - start.y) / 2
                    guard halfLength <= Self.maximumEdgeReachMeters,
                          let cell = Self.cell(x: midpointX, y: midpointY)
                    else {
                        alwaysScanned.append(index)
                        continue
                    }
                    reach = max(reach, halfLength)
                    cells[cell, default: []].append(index)
                }

                self.origin = origin
                self.cells = cells
                self.alwaysScanned = alwaysScanned
                reachMeters = reach
            }

            /// The cell holding a point in the shared frame, or `nil` when the
            /// point isn't finite — a malformed node must not trap here, and
            /// the exhaustive projection rejects it anyway.
            private static func cell(x: Double, y: Double) -> Cell? {
                let cellX = (x / cellSizeMeters).rounded(.down)
                let cellY = (y / cellSizeMeters).rounded(.down)
                guard cellX.isFinite, cellY.isFinite,
                      cellX.magnitude < Double(Int32.max),
                      cellY.magnitude < Double(Int32.max)
                else {
                    return nil
                }
                return Cell(x: Int32(cellX), y: Int32(cellY))
            }

            /// Calls `body` once for every edge that could lie within `radius`
            /// of `coordinate`. Never misses one; may offer a few that turn
            /// out to be beyond it, which the caller's exact projection then
            /// rejects.
            func forEachEdge(
                near coordinate: CLLocationCoordinate2D,
                within radius: Double,
                _ body: (Int) -> Void
            ) {
                for index in alwaysScanned { body(index) }
                guard !cells.isEmpty else { return }

                let centre = RouteGeometry.localOffset(
                    from: origin,
                    to: coordinate
                )
                let expanded = radius + reachMeters + Self.marginMeters
                guard let minimum = Self.cell(
                    x: centre.x - expanded,
                    y: centre.y - expanded
                ), let maximum = Self.cell(
                    x: centre.x + expanded,
                    y: centre.y + expanded
                ) else {
                    return
                }

                for x in minimum.x...maximum.x {
                    for y in minimum.y...maximum.y {
                        guard let bucket = cells[Cell(x: x, y: y)] else {
                            continue
                        }
                        for index in bucket { body(index) }
                    }
                }
            }
        }

        private let nodes: [Int64: TrailGraphNode]
        private let edges: [TrailGraphEdge]
        /// Every valid edge's endpoint coordinates, resolved once. Reading
        /// them back out of `nodes` per edge per fix put two dictionary probes
        /// on the hottest path in matching.
        private let edgeEndpoints: [EdgeEndpoints]
        private let adjacency: [Int64: [Adjacency]]
        private let grid: EdgeGrid
        private var shortestPathCache: [NodePair: NodePath] = [:]

        init(graph: TrailGraph) {
            let nodeMap = Dictionary(
                uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
            )
            var validEdges: [TrailGraphEdge] = []
            var endpoints: [EdgeEndpoints] = []
            validEdges.reserveCapacity(graph.edges.count)
            endpoints.reserveCapacity(graph.edges.count)
            for edge in graph.edges {
                guard let start = nodeMap[edge.fromNodeID]?.coordinate,
                      let end = nodeMap[edge.toNodeID]?.coordinate
                else {
                    continue
                }
                validEdges.append(edge)
                endpoints.append(EdgeEndpoints(start: start, end: end))
            }
            nodes = nodeMap
            edges = validEdges
            edgeEndpoints = endpoints
            grid = EdgeGrid(endpoints: endpoints)
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

        /// The few graph edges close enough to `point` to be worth scoring.
        ///
        /// The grid narrows the field to the segments whose cells the search
        /// radius reaches; each of those is projected against exactly, and
        /// only the closest ``maximumCandidatesPerFix`` survive — so the
        /// shortlist is kept in a bounded min-max heap and the furthest is
        /// dropped as soon as a nearer one turns up. Sorting even the narrowed
        /// field would order edges only to throw all but eight away.
        func candidates(for point: RecordingPoint) -> [Candidate] {
            let radius = max(50, point.horizontalAccuracy * 3)
            var closest = Heap<Candidate>()

            grid.forEachEdge(near: point.coordinate, within: radius) { edgeIndex in
                let endpoints = edgeEndpoints[edgeIndex]
                let projection = RouteGeometry.project(
                    point.coordinate,
                    onSegmentFrom: endpoints.start,
                    to: endpoints.end
                )
                guard projection.offRouteMeters <= radius else { return }
                closest.insert(
                    Candidate(
                        edgeIndex: edgeIndex,
                        projectedCoordinate: RouteGeometry.interpolate(
                            from: endpoints.start,
                            to: endpoints.end,
                            fraction: projection.fraction
                        ),
                        offsetMeters: edges[edgeIndex].lengthMeters
                            * projection.fraction,
                        offRouteMeters: projection.offRouteMeters
                    )
                )
                if closest.count > maximumCandidatesPerFix {
                    closest.removeMax()
                }
            }

            var result: [Candidate] = []
            result.reserveCapacity(closest.count)
            while let next = closest.popMin() { result.append(next) }
            return result
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
                        signature: [
                            Traversal(
                                edgeIndex: start.edgeIndex,
                                isForward: end.offsetMeters
                                    >= start.offsetMeters
                            )
                        ],
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
                                // First-seen order: start edge, then the path's
                                // edges in traversal order, then the end edge.
                                // `Set` would deduplicate just as well but
                                // hand back a hash-seeded order, and this
                                // list is what names the trail to the user.
                                trailNames: OrderedSet(names).elements
                            )
                        )
                    }
                }
            }

            // Insertion-ordered so that two paths tying on both error and
            // distance rank in the order they were generated. A plain
            // `Dictionary` iterates in an order that depends on the process's
            // hash seed, which would let the same recording match one way on
            // one launch and another way on the next.
            var unique: OrderedDictionary<[Traversal], PathOption> = [:]
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

            // Yen's algorithm: keep the accepted paths in order, and every
            // spur path found so far in a priority queue so the next-shortest
            // is a pop rather than a scan of everything still outstanding.
            var accepted = [first]
            var candidates = Heap<RankedPath>()
            // Doubles as the "already accepted" check — an accepted path's
            // edge list is never removed, so a spur that rediscovers it is
            // rejected without comparing edge lists against every accepted
            // path in turn.
            var seenSignatures: Set<[Int]> = [first.edgeIndices]
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
                    guard seenSignatures.insert(edgeIndices).inserted else {
                        continue
                    }
                    candidates.insert(
                        RankedPath(
                            path: NodePath(
                                nodes: nodes,
                                edgeIndices: edgeIndices,
                                distance: rootDistance + spur.distance
                            )
                        )
                    )
                }

                guard let next = candidates.popMin() else { break }
                accepted.append(next.path)
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
            let cacheKey = NodePair(start, end)
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
                    frontier.insert(
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
        ) -> [Traversal] {
            var traversals: [Traversal] = []
            traversals.reserveCapacity(path.edgeIndices.count + 2)
            if startEndpoint.cost > parameters.startEndpointTolerance {
                traversals.append(
                    Traversal(
                        edgeIndex: start.edgeIndex,
                        isForward: startEndpoint.nodeID
                            == edges[start.edgeIndex].toNodeID
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
                        isForward: endEndpoint.nodeID
                            == edges[end.edgeIndex].fromNodeID
                    )
                )
            }
            // An empty list is the stationary case: the pair of candidates is
            // close enough that no edge is walked between them.
            return traversals
        }
    }
}
