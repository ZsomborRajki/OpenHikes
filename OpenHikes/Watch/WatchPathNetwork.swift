//
//  WatchPathNetwork.swift
//  OpenHikes
//
//  Turning the walking graph into the handful of lines a watch can draw.
//
//  The graph this reads is the one a recording is matched against — see
//  ``TrailGraph`` — so nothing new is fetched for most trails and nothing new
//  is cached. It is a graph rather than a drawing: edges between shared nodes,
//  in no particular order, covering a whole region rather than a trail. Three
//  things have to happen before it is a map.
//
//  **Chained.** An edge is one segment of one way. Drawn as it comes, a path
//  of forty segments is forty polylines with thirty-nine coordinates sent
//  twice. Grouped by way and ordered by segment, it is one line.
//
//  **Bounded.** The graph covers the regions the route crosses, which is
//  kilometres of ground in every direction. What a hiker asks a map is "what
//  is that turning" and "where does this fork go", and both are about ground
//  they can see — so everything beyond ``WatchTrailPaths/corridorMeters`` of
//  the route is another walk's map.
//
//  **Capped.** A dense valley has more paths than a watch can draw or a link
//  should carry, so the budget is spent nearest-first: the fork at the hiker's
//  feet before the lane on the far side of the valley.
//

import CoreLocation
import Foundation
import OpenHikesShared

nonisolated enum WatchPathNetwork {
    /// The trail's own line, so the network does not draw it twice.
    ///
    /// A route sent to the watch usually *is* one of these ways, and drawing
    /// it again underneath in the network's colour puts a grey line under a
    /// coloured one along its whole length — visible at every bend where the
    /// two thin differently.
    private static let routeOverlapMeters = 12.0

    /// How coarse a path may be drawn.
    ///
    /// Looser than the route's own thinning: these are context, and a junction
    /// is in the right place at this tolerance even where the lane leading
    /// away from it loses a kink.
    private static let simplificationMeters = 12.0

    /// Builds what should cross the link for one trail.
    ///
    /// `nil` when there is nothing worth sending, which is a real answer:
    /// OSM has nothing here, or everything it has is the route itself.
    static func paths(
        from graph: TrailGraph,
        along route: [CLLocationCoordinate2D],
        hikeID: UUID
    ) -> WatchTrailPaths? {
        guard route.count > 1, !graph.isEmpty else { return nil }
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.coordinate) })
        let corridor = RouteCorridor(route: route)

        let chained = chain(graph.edges, nodes: nodes)
        let candidates = chained.compactMap { line -> Candidate? in
            let clipped = corridor.clip(line)
            guard clipped.count > 1 else { return nil }
            let simplified = simplify(clipped, tolerance: simplificationMeters)
            guard simplified.count > 1 else { return nil }
            return Candidate(line: simplified, distance: corridor.nearestDistance(to: simplified))
        }

        let kept = spend(candidates)
        guard !kept.isEmpty else { return nil }
        return WatchTrailPaths(
            hikeID: hikeID,
            paths: kept.map { line in
                line.map { SharedTrailSnapshot.CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            }
        )
    }

    private struct Candidate {
        let line: [CLLocationCoordinate2D]
        /// How close this path comes to the route, which is the order the
        /// budget is spent in.
        let distance: Double
    }

    /// Nearest first until the budget runs out.
    ///
    /// Whole paths rather than truncated ones: half a lane drawn to a point
    /// that is not a junction reads as a path that stops there, which is worse
    /// than the path being absent. A line too long to afford is skipped and
    /// the next one is tried, because one long way should not eat the budget
    /// four junctions were waiting for.
    private static func spend(_ candidates: [Candidate]) -> [[CLLocationCoordinate2D]] {
        var spent = 0
        var kept: [[CLLocationCoordinate2D]] = []
        for candidate in candidates.sorted(by: { $0.distance < $1.distance }) {
            guard spent + candidate.line.count <= WatchTrailPaths.pointBudget else { continue }
            spent += candidate.line.count
            kept.append(candidate.line)
        }
        return kept
    }

    /// One line per way, its segments in order.
    private static func chain(
        _ edges: [TrailGraphEdge],
        nodes: [Int64: CLLocationCoordinate2D]
    ) -> [[CLLocationCoordinate2D]] {
        let byWay = Dictionary(grouping: edges) { $0.id.wayID }
        return byWay.values.map { wayEdges in
            let ordered = wayEdges.sorted { $0.id.segmentIndex < $1.id.segmentIndex }
            var line: [CLLocationCoordinate2D] = []
            for edge in ordered {
                guard let from = nodes[edge.fromNodeID], let to = nodes[edge.toNodeID] else { continue }
                // A gap between segments means an edge was dropped; the way
                // restarts rather than drawing a line across the hole.
                if line.isEmpty { line.append(from) } else if !isSamePlace(line[line.count - 1], from) {
                    line.append(from)
                }
                line.append(to)
            }
            return line
        }
        .filter { $0.count > 1 }
    }

    private static func isSamePlace(_ first: CLLocationCoordinate2D, _ second: CLLocationCoordinate2D) -> Bool {
        WatchGeodesy.distanceMeters(
            fromLatitude: first.latitude,
            longitude: first.longitude,
            toLatitude: second.latitude,
            longitude: second.longitude
        ) < 1
    }

    /// Drops points that say nothing, keeping the ends.
    ///
    /// Perpendicular distance from the line between the kept neighbours, which
    /// is the same test `WatchTrailPackaging` uses on a route, with a looser
    /// tolerance for the reason ``simplificationMeters`` gives.
    private static func simplify(
        _ line: [CLLocationCoordinate2D],
        tolerance: Double
    ) -> [CLLocationCoordinate2D] {
        guard line.count > 2 else { return line }
        var kept: [CLLocationCoordinate2D] = [line[0]]
        for index in 1..<(line.count - 1) {
            let previous = kept[kept.count - 1]
            let next = line[index + 1]
            if distance(from: line[index], toSegmentFrom: previous, to: next) >= tolerance {
                kept.append(line[index])
            }
        }
        kept.append(line[line.count - 1])
        return kept
    }

    /// How far a point falls from a segment, through the projection
    /// ``WatchRouteTracker`` matches fixes with — one implementation of the
    /// arithmetic, not two.
    private static func distance(
        from point: CLLocationCoordinate2D,
        toSegmentFrom start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        WatchGeodesy.project(
            latitude: point.latitude,
            longitude: point.longitude,
            onSegmentFromLatitude: start.latitude,
            longitude: start.longitude,
            toLatitude: end.latitude,
            longitude: end.longitude
        ).offRouteMeters
    }

    /// The ground either side of the route, and what it does to a path.
    private struct RouteCorridor {
        let route: [CLLocationCoordinate2D]

        /// Keeps only the run of a path that is inside the corridor, and drops
        /// what lies on the route itself.
        ///
        /// Returns the longest surviving run rather than every run, because a
        /// path that leaves the corridor and comes back is two lanes as far as
        /// a hiker is concerned and sending both spends the budget twice.
        func clip(_ line: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
            var best: [CLLocationCoordinate2D] = []
            var current: [CLLocationCoordinate2D] = []
            for point in line {
                let distance = nearestDistance(to: point)
                if distance <= WatchTrailPaths.corridorMeters, distance > routeOverlapMeters {
                    current.append(point)
                } else {
                    if current.count > best.count { best = current }
                    current = []
                }
            }
            return current.count > best.count ? current : best
        }

        func nearestDistance(to line: [CLLocationCoordinate2D]) -> Double {
            line.map { nearestDistance(to: $0) }.min() ?? .greatestFiniteMagnitude
        }

        func nearestDistance(to point: CLLocationCoordinate2D) -> Double {
            guard route.count > 1 else {
                return route.first.map { start in
                    WatchGeodesy.distanceMeters(
                        fromLatitude: point.latitude,
                        longitude: point.longitude,
                        toLatitude: start.latitude,
                        longitude: start.longitude
                    )
                } ?? .greatestFiniteMagnitude
            }
            var nearest = Double.greatestFiniteMagnitude
            for index in 0..<(route.count - 1) {
                let distance = WatchPathNetwork.distance(
                    from: point,
                    toSegmentFrom: route[index],
                    to: route[index + 1]
                )
                if distance < nearest { nearest = distance }
            }
            return nearest
        }
    }
}
