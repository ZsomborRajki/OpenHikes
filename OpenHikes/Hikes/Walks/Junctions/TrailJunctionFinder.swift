//
//  TrailJunctionFinder.swift
//  OpenHikes
//
//  Where a trail meets another, read off the trail graph along the line a
//  hiker is following, and what to do at each to stay on it.
//
//  ## A junction is a node three trails share
//
//  The graph splits every way at every node, so a node two ways share is
//  where they meet, and a node with three or more trails leaving it is a
//  place a hiker can go wrong. Roads are not asked about: the graph a walk
//  reads holds trails alone (*The trail graph squares* in `AGENTS.md`), so a
//  turn onto a lane is not announced, and neither is crossing one.
//
//  ## The line has to be on the ways it is said to take
//
//  A drawn trail is snapped to the graph and passes through its nodes; a
//  recorded one wanders a few metres either side. So a node counts when the
//  line passes within ``nodeReachMeters`` of it, and then only if the line
//  arrives along one of its ways and leaves along another, each within
//  ``wayAgreementDegrees``. A line that passes a junction without following
//  its ways — a recording across a meadow, a road the graph does not hold —
//  says nothing there, because nothing said there could be trusted.
//
//  ## What to say
//
//  Nothing, where the line goes straight on and every other way leaves at a
//  wide angle: no hiker needs telling to keep walking. *Keep left* or *keep
//  right* where two or more ways go on ahead and the line takes the outer
//  one. Otherwise the turn the line makes, by its angle. Each is worked out
//  for both directions of travel from the same geometry — see
//  ``TrailJunction``.
//
//  ## Off the main actor
//
//  The graph for a day's walk is tens of thousands of nodes. ``junctions(along:in:)``
//  indexes the junction nodes in a grid and walks the line once against it.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated enum TrailJunctionFinder {
    /// How close the line must pass a node for the node to be on it.
    /// A recording's spread either side of the path it was walked on, and
    /// narrower than the gap between two paths that run side by side.
    static let nodeReachMeters: Double = 15
    /// How far along each way, and along the line either side, its direction
    /// is read. Long enough to see past the first few metres a junction is
    /// often mapped bent in, short enough to stay at this junction.
    static let armMeters: Double = 25
    /// A way that ends sooner than this at a dead end is a mapping stub, not
    /// a choice.
    static let minimumArmMeters: Double = 4
    /// How far the line's direction may differ from a way's for the line to
    /// be on that way.
    static let wayAgreementDegrees: Double = 45
    /// A line within this of straight on, with nothing else close to it, needs
    /// no word.
    static let straightDegrees: Double = 30
    /// How far from straight on every other way has to leave for straight on
    /// to be obvious.
    static let competingDegrees: Double = 60
    /// Ways within this of straight on are the ones going on ahead, which
    /// is what makes a fork.
    static let aheadDegrees: Double = 75
    /// A turn wider than this is a sharp one.
    static let sharpDegrees: Double = 120
    /// Hits on one node closer than this along the line are one pass of it.
    static let passMergeMeters: Double = 30
    /// Most junctions one line is given. A day's trail meets far fewer; this
    /// bounds a corrupt line or a park of paths.
    static let junctionBudget = 500

    /// How many trails leave a node that is a junction.
    static let junctionDegree = 3
    /// The grid the junction nodes are filed in, in degrees: about fifty
    /// metres of latitude.
    private static let cellDegrees: Double = 0.0005
    /// Most cells one leg of the line may search. A leg that would search
    /// more is kilometres long — a straight line across a gap — and no
    /// junction is announced along it.
    private static let maximumCellsPerLeg = 4096
    /// A floor on a degree of longitude's share of a degree of latitude, so
    /// a leg beside a pole searches a bounded number of cells.
    private static let minimumLongitudeScale = 0.01

    /// The junctions along `profile`, read from the graph already on the
    /// device where it covers the whole line and from a download where it
    /// does not, or none when there is no graph to be had.
    ///
    /// Quiet on failure, as ``HikeTrailAnalysis`` is: a walk with no
    /// junctions found is a walk without warnings, not an error to show.
    @concurrent
    static func junctions(
        along profile: RouteProfile,
        from provider: (any TrailGraphProviding)?
    ) async -> [TrailJunction] {
        guard let provider, profile.coordinates.count > 1 else { return [] }
        let coordinates = profile.coordinates
        let graph = if await provider.hasCompleteCachedGraph(covering: coordinates) {
            try? await provider.cachedGraph(covering: coordinates)
        } else {
            try? await provider.graph(covering: coordinates)
        }
        guard let graph else { return [] }
        return junctions(along: profile, in: graph)
    }

    /// Every junction along `profile`'s line that something should be said
    /// about, ordered by distance, on the line's own scale.
    static func junctions(along profile: RouteProfile, in graph: TrailGraph) -> [TrailJunction] {
        let line = profile.coordinates
        guard line.count > 1, !graph.isEmpty else { return [] }
        let network = Network(graph)
        guard !network.junctionNodes.isEmpty else { return [] }
        let passes = Self.passes(along: profile, of: network)
        var result: [TrailJunction] = []
        for pass in passes {
            guard let junction = junction(at: pass, along: profile, in: network) else { continue }
            result.append(junction)
            if result.count == junctionBudget { break }
        }
        return result
    }

    // MARK: Passes

    /// One time the line goes by a junction node.
    struct Pass {
        let nodeID: Int64
        let distanceMeters: Double
    }

    /// Every pass of the line by a junction node, ordered along the line.
    static func passes(along profile: RouteProfile, of network: Network) -> [Pass] {
        let line = profile.coordinates
        let distances = profile.distances
        var hits: [Int64: [(along: Double, offset: Double)]] = [:]
        for index in line.indices.dropLast() {
            let length = distances[index + 1] - distances[index]
            // A paused leg has no length on the line, and is a drive or a
            // lift rather than ground walked.
            guard length > 0 else { continue }
            let start = line[index]
            let end = line[index + 1]
            for nodeID in network.junctionNodes(near: start, end, within: nodeReachMeters) {
                guard let node = network.nodes[nodeID] else { continue }
                let projection = RouteGeometry.project(node.coordinate, onSegmentFrom: start, to: end)
                guard projection.offRouteMeters <= nodeReachMeters else { continue }
                hits[nodeID, default: []].append(
                    (distances[index] + projection.fraction * length, projection.offRouteMeters)
                )
            }
        }
        var passes: [Pass] = []
        for (nodeID, nodeHits) in hits {
            var closest: (along: Double, offset: Double)?
            var lastAlong = -Double.infinity
            for hit in nodeHits.sorted(by: { $0.along < $1.along }) {
                if hit.along - lastAlong > passMergeMeters, let finished = closest {
                    passes.append(Pass(nodeID: nodeID, distanceMeters: finished.along))
                    closest = nil
                }
                if closest.map({ hit.offset < $0.offset }) ?? true { closest = hit }
                lastAlong = hit.along
            }
            if let closest { passes.append(Pass(nodeID: nodeID, distanceMeters: closest.along)) }
        }
        return passes.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    // MARK: One junction

    /// What to say at `pass` walking either way, or `nil` when the line does
    /// not follow the ways there or there is nothing to say either way.
    static func junction(at pass: Pass, along profile: RouteProfile, in network: Network) -> TrailJunction? {
        let along = pass.distanceMeters
        guard along >= armMeters, along <= profile.totalDistanceMeters - armMeters,
              !profile.pauseDistances.contains(where: { abs($0 - along) < armMeters }),
              let before = profile.coordinate(atDistance: along - armMeters),
              let here = profile.coordinate(atDistance: along),
              let after = profile.coordinate(atDistance: along + armMeters),
              let node = network.nodes[pass.nodeID]
        else { return nil }
        let lineIn = bearing(from: before, to: here)
        let lineOut = bearing(from: here, to: after)
        let ways = network.wayBearings(from: node, armMeters: armMeters, minimumMeters: minimumArmMeters)
        guard let arrival = closest(ways, to: lineIn + 180),
              let exit = closest(ways, to: lineOut),
              arrival != exit
        else { return nil }
        let others = ways.indices.filter { $0 != arrival && $0 != exit }.map { ways[$0] }
        guard !others.isEmpty else { return nil }
        let towardsEnd = maneuver(heading: lineIn, exit: ways[exit], others: others)
        let towardsStart = maneuver(heading: lineOut + 180, exit: ways[arrival], others: others)
        guard towardsEnd != nil || towardsStart != nil else { return nil }
        return TrailJunction(distanceMeters: along, towardsEnd: towardsEnd, towardsStart: towardsStart)
    }

    /// The index of the way in `ways` closest to `wanted`, if it is within
    /// ``wayAgreementDegrees``.
    private static func closest(_ ways: [Double], to wanted: Double) -> Int? {
        let difference = { (index: Int) in RouteGeometry.bearingDifference(ways[index], wanted) }
        guard let index = ways.indices.min(by: { difference($0) < difference($1) }),
              difference(index) <= wayAgreementDegrees
        else { return nil }
        return index
    }

    /// What a hiker arriving on `heading` does to leave by `exit` rather than
    /// by any of `others`, or `nil` when going straight on is obvious.
    static func maneuver(heading: Double, exit: Double, others: [Double]) -> JunctionManeuver? {
        let turn = relative(exit, to: heading)
        let alternatives = others.map { relative($0, to: heading) }
        if abs(turn) <= straightDegrees, alternatives.allSatisfy({ abs($0) >= competingDegrees }) {
            return nil
        }
        let ahead = ([turn] + alternatives).filter { abs($0) <= aheadDegrees }
        if abs(turn) <= aheadDegrees, ahead.count > 1 {
            if turn <= (ahead.min() ?? turn) { return .keepLeft }
            if turn >= (ahead.max() ?? turn) { return .keepRight }
            return .straight
        }
        if abs(turn) <= straightDegrees { return .straight }
        if abs(turn) <= sharpDegrees { return turn < 0 ? .turnLeft : .turnRight }
        return turn < 0 ? .sharpLeft : .sharpRight
    }

    /// `bearing` as seen by a hiker facing `heading`: negative to their left,
    /// positive to their right, in `-180..<180`.
    static func relative(_ bearing: Double, to heading: Double) -> Double {
        let delta = (bearing - heading).truncatingRemainder(dividingBy: 360)
        return delta < -180 ? delta + 360 : delta >= 180 ? delta - 360 : delta
    }

    /// The compass bearing from `start` to `end`, in `0..<360`.
    static func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let offset = RouteGeometry.localOffset(from: start, to: end)
        let degrees = atan2(offset.x, offset.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    // MARK: The network

    /// The graph's trails as a hiker meets them: which nodes join which, and
    /// where the junctions are.
    struct Network {
        let nodes: [Int64: TrailGraphNode]
        /// Each node's neighbours along a trail, once each.
        let neighbors: [Int64: [Int64]]
        /// The nodes three or more trails leave.
        let junctionNodes: Set<Int64>
        /// ``junctionNodes`` filed by grid cell.
        private let cells: [Cell: [Int64]]

        private struct Cell: Hashable {
            let row: Int
            let column: Int
        }

        init(_ graph: TrailGraph) {
            nodes = graph.nodes.keyed(by: \.id)
            var joined: [Int64: Set<Int64>] = [:]
            for edge in graph.edges where edge.isTrail && edge.fromNodeID != edge.toNodeID {
                joined[edge.fromNodeID, default: []].insert(edge.toNodeID)
                joined[edge.toNodeID, default: []].insert(edge.fromNodeID)
            }
            neighbors = joined.mapValues { $0.sorted() }
            let junctionIDs = Set(joined.filter { $0.value.count >= TrailJunctionFinder.junctionDegree }.keys)
            junctionNodes = junctionIDs
            var filed: [Cell: [Int64]] = [:]
            for nodeID in junctionIDs {
                guard let node = nodes[nodeID] else { continue }
                filed[Self.cell(of: node.coordinate), default: []].append(nodeID)
            }
            cells = filed
        }

        private static func cell(of coordinate: CLLocationCoordinate2D) -> Cell {
            Cell(
                row: Int((coordinate.latitude / TrailJunctionFinder.cellDegrees).rounded(.down)),
                column: Int((coordinate.longitude / TrailJunctionFinder.cellDegrees).rounded(.down))
            )
        }

        /// The junction nodes in the cells a leg from `start` to `end`,
        /// widened by `reach` metres, overlaps.
        func junctionNodes(
            near start: CLLocationCoordinate2D,
            _ end: CLLocationCoordinate2D,
            within reach: Double
        ) -> [Int64] {
            let latitudeReach = reach / RouteGeometry.metersPerDegreeLatitude
            let longitudeReach = reach / (RouteGeometry.metersPerDegreeLatitude
                * max(cos(start.latitude * .pi / 180), TrailJunctionFinder.minimumLongitudeScale))
            // A leg across the antimeridian is a gap, never a walked leg.
            guard abs(end.longitude - start.longitude) < 180 else { return [] }
            let low = Self.cell(of: CLLocationCoordinate2D(
                latitude: min(start.latitude, end.latitude) - latitudeReach,
                longitude: min(start.longitude, end.longitude) - longitudeReach
            ))
            let high = Self.cell(of: CLLocationCoordinate2D(
                latitude: max(start.latitude, end.latitude) + latitudeReach,
                longitude: max(start.longitude, end.longitude) + longitudeReach
            ))
            let rows = high.row - low.row + 1
            let columns = high.column - low.column + 1
            guard rows * columns <= TrailJunctionFinder.maximumCellsPerLeg else { return [] }
            var found: [Int64] = []
            for row in low.row...high.row {
                for column in low.column...high.column {
                    found.append(contentsOf: cells[Cell(row: row, column: column)] ?? [])
                }
            }
            return found
        }

        /// The bearing of each trail leaving `node`, read where it has run
        /// `armMeters` — through the nodes along it that join nothing else —
        /// or where it first meets another junction or ends. A way that ends
        /// before `minimumMeters` is left out.
        ///
        /// Read at `armMeters` itself, part of the way along the edge that
        /// passes it, as the line's own direction is read
        /// (``junction(at:along:in:)``). A way that turns after a short edge
        /// and runs on along a long one would otherwise be read at the long
        /// one's far end, in a direction the line read 25 metres out does not
        /// share, and the junction would be dropped as one the line does not
        /// follow.
        func wayBearings(from node: TrailGraphNode, armMeters: Double, minimumMeters: Double) -> [Double] {
            (neighbors[node.id] ?? []).compactMap { first in
                var previous = node
                guard var current = nodes[first] else { return nil }
                var walked = 0.0
                var edge = RouteGeometry.distanceMeters(from: previous.coordinate, to: current.coordinate)
                while walked + edge < armMeters,
                      let onward = neighbors[current.id], onward.count == 2,
                      let nextID = onward.first(where: { $0 != previous.id }),
                      nextID != node.id,
                      let next = nodes[nextID] {
                    walked += edge
                    edge = RouteGeometry.distanceMeters(from: current.coordinate, to: next.coordinate)
                    previous = current
                    current = next
                }
                let length = walked + edge
                let isDeadEnd = (neighbors[current.id]?.count ?? 0) <= 1
                guard length >= minimumMeters || !isDeadEnd else { return nil }
                let end = length > armMeters
                    ? RouteGeometry.interpolate(
                        from: previous.coordinate,
                        to: current.coordinate,
                        fraction: (armMeters - walked) / edge
                    )
                    : current.coordinate
                return TrailJunctionFinder.bearing(from: node.coordinate, to: end)
            }
        }
    }
}
