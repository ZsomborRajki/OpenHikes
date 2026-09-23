//
//  TrailLegRouter.swift
//  OpenHikes
//
//  Making one leg of a drawn trail follow a real path.
//
//  The machinery under this is entirely borrowed, and that is the point of the
//  phase rather than an economy: ``OverpassTrailGraphProvider`` already
//  downloads the OpenStreetMap walking graph a tile at a time, caches it on
//  disk for a month, coalesces concurrent requests for the same tile and backs
//  off when Overpass says to; ``TrailMatcherGraphIndex`` already indexes that
//  graph spatially and runs Dijkstra over it. A recording uses both to work
//  out where a hiker *went*. This asks the same two objects where a hiker
//  *could* go, and the disk cache a recording filled is the one a drawing
//  reads.
//
//  ## One request per leg, and they are asked one at a time
//
//  Each leg names a corridor — its two ends plus samples along the straight
//  line between them, from ``TrailGraphCorridor`` — and asks the provider for
//  the graph covering it. A hiker putting down twenty points therefore asks
//  nineteen questions rather than one per tap of the map, and most of them are
//  answered from the tile the previous leg already downloaded.
//
//  The legs are routed **sequentially** by ``TrailDraftController`` rather
//  than concurrently, and that is a manners decision about a volunteer-run
//  API: nineteen parallel requests from one phone is the shape that earns a
//  `429`, and the `429` has been hit in the field. Sequential also makes the
//  provider's in-flight coalescing do its job — the second leg of a walk asks
//  for a tile the first is already downloading, and joins it instead of
//  opening a second connection.
//
//  ## What is cached here, and what deliberately is not
//
//  Settled answers are cached by ``TrailLegEnds``, so toggling snapping off
//  and on again costs nothing, and so Phase 3's reorder — which moves rows
//  around without moving anything on the ground — re-resolves only the legs
//  whose two ends actually changed. **A refusal is never cached**, because
//  *Retry* would then have nothing to do. The cache is bounded, oldest first,
//  because the router outlives every drawing — see ``TrailLegAnswerCache``.
//
//  One built index is kept beside it, keyed on the set of regions it was
//  built from. Consecutive legs of one walk are in one area, so the second
//  leg onwards usually reuses it; a leg that reaches into a new tile pays for
//  a rebuild, which is the honest price of a bigger graph. Only one, because
//  a drawn trail is a walk rather than a tour of the country, and an index
//  over a z12 tile is not a thing to keep several of.
//

import Algorithms
import CoreLocation
import Foundation
import os

/// Where a leg's shape comes from.
///
/// A protocol for the reason ``CuratedTrailSourcing`` is one: the conformance
/// below reaches a volunteer-run public API, and no suite may. It is also the
/// seam a preview and a launch with no graph provider go through by simply
/// not having one — see ``TrailDraftController``, which draws straight legs
/// when this is absent rather than pretending to route them.
nonisolated protocol TrailLegRouting: Sendable {
    /// The shape this leg should take, or `nil` when the question was
    /// cancelled and there is nothing to say about it.
    ///
    /// **Never throws, and never answers with nothing to draw.** Every
    /// failure Overpass can produce comes back as a straight line wearing the
    /// reason it is straight, because a hiker drawing a trail must not be
    /// stopped by a busy server. `nil` is reserved for cancellation, which is
    /// not a failure and must not be drawn as one — the same carve-out
    /// ``CuratedTrailOutage/init(_:)`` makes for the same two spellings of it.
    @concurrent
    func route(_ ends: TrailLegEnds) async -> TrailLegRoute?
}

/// Legs routed over the OpenStreetMap walking graph.
actor OverpassTrailLegRouter: TrailLegRouting {
    private static let logger = Logger(subsystem: "OpenHikes", category: "TrailDraft")

    /// How far from a mapped path a tapped point may be and still be taken to
    /// mean that path, in metres.
    ///
    /// The number that decides *does this snap at all*, so it is the number
    /// the phase's "must not snap to something absurd" rests on. A hiker
    /// drawing at the zoom this is used at is aiming at a line they can see,
    /// and a hundred metres is about as far as two Alpine paths are from each
    /// other where it matters — wide enough that a thumb-width miss still
    /// finds the path that was aimed at, narrow enough that a point put down
    /// in a trackless corrie finds nothing and stays where it was put.
    static let snapRadiusMeters = 100.0

    /// How much longer than the straight line a routed leg may be.
    ///
    /// Generous on purpose, because the case this would wrongly reject is the
    /// commonest good one: a path switchbacking up a face is several times
    /// the distance between its ends, and a hiker drawing a climb is drawing
    /// exactly that. What it is actually for is bounding Dijkstra — the
    /// budget is handed to ``TrailMatcherGraphIndex/shortestPath(from:to:maximumDistance:bannedNodes:bannedEdges:)``
    /// as its `maximumDistance`, so a leg between two points on either side
    /// of an unbridged river explores a bounded neighbourhood and gives up,
    /// rather than walking the whole tile to find a crossing ten kilometres
    /// away that no hiker meant.
    static let maximumDetourFactor = 8.0

    /// Added to the budget above, so a short leg is not held to a share of
    /// almost nothing. Two points forty metres apart with a switchback
    /// between them are a normal thing to draw.
    static let minimumDetourAllowanceMeters = 1000.0

    /// The longest leg this will ask about, in metres.
    ///
    /// A leg is the stretch between two points a hiker tapped, and twenty
    /// kilometres of it is already a day's walk in one tap. Past that the
    /// corridor spans enough z12 tiles that one leg would spend several
    /// Overpass requests to route a line the hiker has given no shape to, and
    /// the honest answer is that they should put a point in the middle. Said
    /// out loud in the list rather than silently left straight — see
    /// ``TrailLegGap/tooFarApart``.
    static let maximumLegMeters = 20_000.0

    /// How many other ways a leg offers beside the one it draws — Apple Maps
    /// shows at most three routes in all.
    static let maximumAlternatives = 2

    /// How much longer than the best an alternative may be. A route half as
    /// long again is a real choice on foot; twice as long is a different walk.
    static let maximumAlternativeStretch = 1.5

    /// How much of an alternative may run along a route already offered.
    static let maximumSharedFraction = 0.7

    /// The graph index that was last built, and the regions it came from.
    private struct BuiltIndex {
        let regions: Set<TrailGraphRegion>
        var value: TrailMatcherGraphIndex
    }

    /// Where a coordinate lands on the nearest mapped path.
    ///
    /// Not `private`: the routing below is a `private extension`, whose
    /// members are `fileprivate`, and Swift refuses a `fileprivate` method
    /// that takes a `private` type.
    struct SnapPoint {
        let edgeIndex: Int
        let coordinate: CLLocationCoordinate2D
        /// How far along its edge the projection sits, from the edge's
        /// `fromNodeID`.
        let offsetMeters: Double
    }

    private let provider: any TrailGraphProviding
    /// Bounded, because this router lives as long as the app — see
    /// ``TrailLegAnswerCache``.
    private var cache = TrailLegAnswerCache()
    private var index: BuiltIndex?

    init(provider: any TrailGraphProviding) {
        self.provider = provider
    }

    func route(_ ends: TrailLegEnds) async -> TrailLegRoute? {
        if let cached = cache[ends] { return cached }
        guard ends.straightDistanceMeters <= Self.maximumLegMeters else {
            return settling(.straight(along: ends, .unmapped(.tooFarApart)), for: ends)
        }
        let corridor = Self.corridor(along: ends)
        do {
            let graph = try await graph(covering: corridor)
            try Task.checkCancellation()
            guard let graph, !graph.isEmpty else {
                return settling(.straight(along: ends, .unmapped(.noPathBetween)), for: ends)
            }
            return settling(resolve(ends, over: graph, covering: corridor), for: ends)
        } catch {
            // A cancelled leg is not a degraded one. The draft changed under
            // the question — a point went down, or the maker closed — and
            // drawing *OpenStreetMap unavailable* on a line nobody is waiting
            // for would be a warning about the hiker's own pan.
            guard let outage = CuratedTrailOutage(error) else { return nil }
            Self.logger.info(
                """
                A drawn leg could not be routed: \
                \(String(describing: outage), privacy: .public)
                """
            )
            // Deliberately not cached: *Retry* has to be able to ask again.
            return .straight(along: ends, .refused(outage))
        }
    }

    /// Remembers a settled answer, and hands it straight back.
    ///
    /// Only the settled ones: a refusal never reaches here. See the file
    /// header.
    private func settling(_ route: TrailLegRoute, for ends: TrailLegEnds) -> TrailLegRoute {
        cache.store(route, for: ends)
        return route
    }

    /// The graph covering one leg's corridor, downloading whatever it crosses
    /// that is not cached yet.
    ///
    /// ``TrailGraphProviding/graph(covering:)`` skips a region it could not
    /// fetch rather than abandoning the rest, and throws only when nothing at
    /// all could be assembled. For a leg inside one tile — which is nearly all
    /// of them — that is exactly the reporting this wants. For a leg spanning
    /// two, a half-answered corridor can come back as
    /// ``TrailLegGap/noPathBetween`` rather than as a refusal, which
    /// understates one uncommon case and never overstates any: it says *there
    /// is no path here*, and the retry that would fix it is another tap on the
    /// map rather than the *Retry* button.
    private func graph(
        covering corridor: [CLLocationCoordinate2D]
    ) async throws -> TrailGraph? {
        try await provider.graph(covering: corridor)
    }

    /// The points a leg's graph has to cover: its two ends, and enough of the
    /// line between them that a long leg cannot step over a whole region
    /// without landing inside it.
    ///
    /// ``TrailGraphCorridor`` owns that sampling already, for the stretches a
    /// recording lost its fixes across — which is the same geometry problem
    /// with a different cause.
    private static func corridor(along ends: TrailLegEnds) -> [CLLocationCoordinate2D] {
        [ends.startCoordinate]
            + TrailGraphCorridor.samples(
                from: ends.startCoordinate,
                to: ends.endCoordinate
            )
            + [ends.endCoordinate]
    }

    /// Routes `ends` over `graph`, reusing the built index when the corridor
    /// resolves to the same regions as the last one.
    private func resolve(
        _ ends: TrailLegEnds,
        over graph: TrailGraph,
        covering corridor: [CLLocationCoordinate2D]
    ) -> TrailLegRoute {
        let regions = Set(corridor.compactMap(provider.region(containing:)))
        var built = index?.regions == regions
            ? (index?.value ?? TrailMatcherGraphIndex(graph: graph))
            : TrailMatcherGraphIndex(graph: graph)
        let route = Self.route(ends, using: &built)
        index = BuiltIndex(regions: regions, value: built)
        return route
    }
}

// MARK: - The routing itself

// `nonisolated` on the extension rather than on its members, the rule the
// repository instructions state: with `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor` an unannotated extension is a main-actor context, and Dijkstra
// over a tile's worth of edges is the last thing that belongs on the main
// thread. Static because none of it touches the actor's state — the index is
// handed in `inout` so its own shortest-path cache is kept.
nonisolated private extension OverpassTrailLegRouter {
    static func route(
        _ ends: TrailLegEnds,
        using index: inout TrailMatcherGraphIndex
    ) -> TrailLegRoute {
        guard let start = snapPoint(for: ends.startCoordinate, in: index),
              let end = snapPoint(for: ends.endCoordinate, in: index) else {
            return .straight(along: ends, .unmapped(.noPathBetween))
        }
        // Both ends on one edge: the edge itself is the way, and there is
        // nothing to offer beside it.
        guard start.edgeIndex != end.edgeIndex else {
            return route(along: [shape(through: nil, from: start, to: end, along: ends, in: index)])
        }
        guard let best = path(from: start, to: end, using: &index, ceiling: budget(along: ends)) else {
            return .straight(along: ends, .unmapped(.noPathBetween))
        }
        let paths = [best.path] + alternatives(to: best, from: start, to: end, using: &index)
        return route(along: paths.map { path in
            shape(through: path, from: start, to: end, along: ends, in: index)
        })
    }

    /// The first shape drawn, the rest offered beside it.
    static func route(along shapes: [[CLLocationCoordinate2D]]) -> TrailLegRoute {
        let paths = shapes.map { shape in
            TrailLegPath(
                coordinates: shape.map { RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                distanceMeters: length(of: shape)
            )
        }
        return TrailLegRoute(
            coordinates: paths[0].coordinates,
            distanceMeters: paths[0].distanceMeters,
            snap: .snapped,
            alternatives: Array(paths.dropFirst())
        )
    }

    /// The whole drawn shape of a snapped leg through `path`, or along the one
    /// edge both ends snapped onto when there is no path.
    ///
    /// **It starts and ends at the waypoints, not at their projections.** A
    /// tapped point stays where it was tapped: moving it onto the path would
    /// be the app putting down a point the hiker did not, and turning
    /// snapping off again could not put it back. What that costs is a short
    /// connector at either end — at most ``snapRadiusMeters`` of it, and
    /// nothing at all when the tap landed on the line, which is the usual
    /// case.
    static func shape(
        through path: TrailMatcherGraphIndex.NodePath?,
        from start: SnapPoint,
        to end: SnapPoint,
        along ends: TrailLegEnds,
        in index: TrailMatcherGraphIndex
    ) -> [CLLocationCoordinate2D] {
        var shape = [ends.startCoordinate, start.coordinate]
        if let path {
            shape.append(contentsOf: path.nodes.compactMap { index.nodes[$0]?.coordinate })
        }
        shape.append(contentsOf: [end.coordinate, ends.endCoordinate])
        return index.deduplicated(shape)
    }

    /// A way through the graph, and what it costs end to end — the node path
    /// plus the stretch of snapped edge at either end.
    struct FoundPath {
        let path: TrailMatcherGraphIndex.NodePath
        let total: Double
    }

    /// The cheapest way through the graph between the two edges the ends
    /// snapped onto, avoiding `banned` edges and costing no more than
    /// `ceiling` end to end.
    ///
    /// Four combinations, because either end of either edge can be the one
    /// the route leaves through — the same enumeration
    /// ``TrailMatcherGraphIndex/transition(from:to:parameters:)`` makes for a
    /// recording's transitions, and for the same reason: an edge is a segment
    /// between two nodes, and a point part-way along it can be left in either
    /// direction.
    static func path(
        from start: SnapPoint,
        to end: SnapPoint,
        using index: inout TrailMatcherGraphIndex,
        ceiling: Double,
        banning banned: Set<Int> = []
    ) -> FoundPath? {
        var best: FoundPath?
        for (from, to) in product(endpoints(of: start, in: index), endpoints(of: end, in: index)) {
            let available = ceiling - from.cost - to.cost
            guard available >= 0,
                  let path = index.shortestPath(
                      from: from.nodeID,
                      to: to.nodeID,
                      maximumDistance: available,
                      bannedNodes: [],
                      bannedEdges: banned
                  ) else { continue }
            let total = from.cost + path.distance + to.cost
            if let current = best, current.total <= total { continue }
            best = FoundPath(path: path, total: total)
        }
        return best
    }

    /// How far a leg may wander before it is not the leg the hiker drew.
    static func budget(along ends: TrailLegEnds) -> Double {
        min(
            maximumLegMeters,
            ends.straightDistanceMeters * maximumDetourFactor + minimumDetourAllowanceMeters
        )
    }

    /// Up to ``maximumAlternatives`` other ways between the same two snapped
    /// points, each genuinely different from what is already on offer.
    ///
    /// Not Yen's k-shortest paths, which ``TrailMatcherGraphIndex`` also
    /// offers: on a path network the second- and third-shortest are the
    /// shortest with one corner cut differently, which is not a choice anyone
    /// would tap. Each round bans the **middle half** of every path found so
    /// far and asks again, so what comes back has to leave the others somewhere
    /// in the middle and rejoin them — a different valley, the other side of a
    /// lake. What shares more than ``maximumSharedFraction`` of its length with
    /// one already found, or costs more than ``maximumAlternativeStretch``
    /// times the best end to end, is not offered.
    ///
    /// Asked through the same four combinations the best path is, because the
    /// best may leave its snapped edge through an interior node an alternative
    /// has no use for.
    static func alternatives(
        to best: FoundPath,
        from start: SnapPoint,
        to end: SnapPoint,
        using index: inout TrailMatcherGraphIndex
    ) -> [TrailMatcherGraphIndex.NodePath] {
        let ceiling = best.total * maximumAlternativeStretch
        var offered = [best.path]
        while offered.count <= maximumAlternatives {
            let banned = offered.reduce(into: Set<Int>()) { banned, path in
                banned.formUnion(middleEdges(of: path, in: index))
            }
            guard !banned.isEmpty,
                  let candidate = path(from: start, to: end, using: &index, ceiling: ceiling, banning: banned),
                  isDistinct(candidate.path, from: offered, in: index) else { break }
            offered.append(candidate.path)
        }
        return Array(offered.dropFirst())
    }

    /// The edges that reach into the middle half of `path`'s length — every
    /// one of them, however short the path, so a path of one or two edges
    /// still has something to be different from.
    static func middleEdges(
        of path: TrailMatcherGraphIndex.NodePath,
        in index: TrailMatcherGraphIndex
    ) -> Set<Int> {
        let middle = (path.distance / 4)...(path.distance * 3 / 4)
        var travelled = 0.0
        var banned = Set<Int>()
        for edge in path.edgeIndices {
            let length = index.edges[edge].lengthMeters
            if (travelled...(travelled + length)).overlaps(middle) { banned.insert(edge) }
            travelled += length
        }
        return banned
    }

    static func isDistinct(
        _ candidate: TrailMatcherGraphIndex.NodePath,
        from offered: [TrailMatcherGraphIndex.NodePath],
        in index: TrailMatcherGraphIndex
    ) -> Bool {
        guard candidate.distance > 0 else { return false }
        let own = Set(candidate.edgeIndices)
        return offered.allSatisfy { path in
            let shared = own.intersection(path.edgeIndices)
                .reduce(0) { $0 + index.edges[$1].lengthMeters }
            return shared <= candidate.distance * maximumSharedFraction
        }
    }

    /// The two nodes a snapped point can leave its edge through, and what
    /// reaching each of them costs.
    static func endpoints(
        of point: SnapPoint,
        in index: TrailMatcherGraphIndex
    ) -> [TrailMatcherGraphIndex.Endpoint] {
        let edge = index.edges[point.edgeIndex]
        return [
            TrailMatcherGraphIndex.Endpoint(
                nodeID: edge.fromNodeID,
                cost: point.offsetMeters
            ),
            TrailMatcherGraphIndex.Endpoint(
                nodeID: edge.toNodeID,
                cost: max(0, edge.lengthMeters - point.offsetMeters)
            ),
        ]
    }

    /// The nearest mapped path to `coordinate`, or `nil` when nothing is
    /// within ``snapRadiusMeters`` of it.
    ///
    /// Goes through the index's own spatial grid rather than scanning every
    /// edge, which is the whole reason that grid exists: a z12 tile of Alpine
    /// mapping is thousands of segments, and this runs once per leg end.
    static func snapPoint(
        for coordinate: CLLocationCoordinate2D,
        in index: TrailMatcherGraphIndex
    ) -> SnapPoint? {
        var best: SnapPoint?
        var bestOffRoute = Double.infinity
        index.grid.forEachEdge(near: coordinate, within: snapRadiusMeters) { edgeIndex in
            let endpoints = index.edgeEndpoints[edgeIndex]
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: endpoints.start,
                to: endpoints.end
            )
            guard projection.offRouteMeters <= snapRadiusMeters,
                  projection.offRouteMeters < bestOffRoute else { return }
            bestOffRoute = projection.offRouteMeters
            best = SnapPoint(
                edgeIndex: edgeIndex,
                coordinate: RouteGeometry.interpolate(
                    from: endpoints.start,
                    to: endpoints.end,
                    fraction: projection.fraction
                ),
                offsetMeters: index.edges[edgeIndex].lengthMeters * projection.fraction
            )
        }
        return best
    }

    /// Measured along the drawn shape rather than reported by the router,
    /// so the number in the header is the length of the line on the screen.
    static func length(of shape: [CLLocationCoordinate2D]) -> Double {
        shape.adjacentPairs().reduce(0) { total, pair in
            total + RouteGeometry.distanceMeters(from: pair.0, to: pair.1)
        }
    }
}
