//
//  TrailSurfaceBreakdown.swift
//  OpenHikes
//
//  How much of a route runs on each kind of surface, derived by projecting the
//  route onto the cached OSM trail graph and reading the `surface` tagging off
//  the ways it lands on.
//

import CoreLocation
import Foundation

nonisolated struct TrailSurfaceBreakdown: Equatable, Sendable {
    nonisolated struct Share: Identifiable, Equatable, Sendable {
        var id: TrailSurface { surface }
        let surface: TrailSurface
        let meters: Double
        /// Portion of ``TrailSurfaceBreakdown/totalMeters``, in `0...1`.
        let fraction: Double
    }

    /// Every surface with a non-zero share, surveyed categories first and
    /// longest first within each group, so the leading entry is the answer to
    /// "what did I mostly walk on".
    let shares: [Share]
    /// Route length as measured by this walk, which is the sum of the shares
    /// rather than ``Hike/distanceMeters`` — the two agree to within rounding,
    /// and using the sum keeps the fractions adding up to exactly 1.
    let totalMeters: Double

    static let empty = Self(shares: [], totalMeters: 0)

    var isEmpty: Bool { shares.isEmpty }

    /// The single biggest share, or `nil` for an empty breakdown.
    var dominant: Share? { shares.first }

    /// How much of the route OSM actually describes. A low value means the
    /// percentages below it are drawn from a small sample and should be read
    /// as such — which is why the unsurveyed remainder is charted rather than
    /// quietly dropped.
    var surveyedFraction: Double {
        shares.reduce(0) { total, share in
            share.surface.isSurveyed ? total + share.fraction : total
        }
    }

    func meters(for surface: TrailSurface) -> Double {
        shares.first { $0.surface == surface }?.meters ?? 0
    }

    private init(shares: [Share], totalMeters: Double) {
        self.shares = shares
        self.totalMeters = totalMeters
    }

    init(metersBySurface: [TrailSurface: Double]) {
        let total = metersBySurface.values.reduce(0, +)
        guard total > 0 else {
            self = .empty
            return
        }
        totalMeters = total
        shares = metersBySurface
            .filter { _, meters in meters > 0 }
            .map { surface, meters in
                Share(
                    surface: surface,
                    meters: meters,
                    fraction: meters / total
                )
            }
            .sorted { lhs, rhs in
                if lhs.surface.isSurveyed != rhs.surface.isSurveyed { return lhs.surface.isSurveyed }
                if lhs.meters != rhs.meters { return lhs.meters > rhs.meters }
                return lhs.surface.displayOrder < rhs.surface.displayOrder
            }
    }
}

// MARK: - Analysis

nonisolated enum TrailSurfaceAnalyzer {
    /// How far a sample may sit from a way before that way stops being a
    /// plausible explanation for it. Deliberately wider than the matcher's own
    /// tolerance for moving geometry: attributing a surface is a much cheaper
    /// claim than relocating a route, and an imported GPX can be a good 20 m
    /// off a correctly mapped trail under tree cover.
    static let defaultToleranceMeters = 25.0
    /// Distance between samples. Small enough to catch the short paved
    /// connectors between trail sections, large enough that a five-hour track
    /// is a few thousand grid lookups rather than a few hundred thousand.
    static let samplingStepMeters = 20.0
    /// How much closer a rival way has to be before a sample abandons the way
    /// the previous sample used. Without it a route running between a path and
    /// the service road beside it alternates between them fix by fix, and the
    /// breakdown reports a 50/50 split of a walk that only ever used one.
    ///
    /// Kept well under half of ``samplingStepMeters`` on purpose: the first
    /// sample past a junction sits half a step beyond it, so the way just left
    /// is already further away than this and a genuine turn is never held on
    /// to.
    static let wayStickinessMeters = 5.0
    /// Ceiling on the samples one segment may contribute, so a single corrupt
    /// coordinate can't turn into an unbounded loop.
    static let maximumStepsPerSegment = 512
    /// How often the walk checks for cancellation, in samples.
    private static let cancellationCheckInterval = 255

    /// Attributes every metre of `route` to a surface.
    ///
    /// This is a read-only measurement, not a match: it never moves the route,
    /// and a stretch with no way beneath it is reported as
    /// ``TrailSurface/unmapped`` rather than snapped to the nearest thing
    /// available. Running the full HMM matcher here would be both slower and
    /// less honest — it exists to decide where a walker *was*, and its answer
    /// for a leg it is unsure about is a straight line, which has no surface.
    @concurrent
    static func breakdown(
        route: [RouteCoordinate],
        graph: TrailGraph,
        toleranceMeters: Double = defaultToleranceMeters
    ) async throws(CancellationError) -> TrailSurfaceBreakdown {
        assertOffMainThread(
            "Trail surface analysis must stay off the main thread"
        )
        guard route.count > 1, !graph.isEmpty else { return .empty }
        let index = TrailMatcherGraphIndex(graph: graph)
        guard !index.edges.isEmpty else { return .empty }

        var metersBySurface: [TrailSurface: Double] = [:]
        var previousWayID: Int64?
        var samplesTaken = 0

        for (start, end) in zip(route, route.dropFirst()) {
            let from = start.clCoordinate
            let to = end.clCoordinate
            let segmentMeters = RouteGeometry.distanceMeters(from: from, to: to)
            guard segmentMeters.isFinite, segmentMeters > 0 else { continue }

            let steps = min(
                max(Int((segmentMeters / samplingStepMeters).rounded(.up)), 1),
                maximumStepsPerSegment
            )
            let stepMeters = segmentMeters / Double(steps)
            for step in 0..<steps {
                if samplesTaken.isMultiple(of: cancellationCheckInterval),
                   Task.isCancelled { throw CancellationError() }
                samplesTaken += 1
                // The midpoint of each sub-step, so a sample never lands
                // exactly on a junction where two differently surfaced ways
                // meet and the choice between them is a coin toss.
                let sample = RouteGeometry.interpolate(
                    from: from,
                    to: to,
                    fraction: (Double(step) + 0.5) / Double(steps)
                )
                let edgeIndex = nearestEdgeIndex(
                    to: sample,
                    in: index,
                    within: toleranceMeters,
                    preferringWay: previousWayID
                )
                let surface: TrailSurface
                if let edgeIndex {
                    let edge = index.edges[edgeIndex]
                    surface = TrailSurface(edge: edge)
                    previousWayID = edge.id.wayID
                } else {
                    surface = .unmapped
                    previousWayID = nil
                }
                metersBySurface[surface, default: 0] += stepMeters
            }
        }

        return TrailSurfaceBreakdown(metersBySurface: metersBySurface)
    }

    /// The closest way to `coordinate`, with a bias towards staying on the way
    /// the previous sample used — see ``wayStickinessMeters``.
    static func nearestEdgeIndex(
        to coordinate: CLLocationCoordinate2D,
        in index: TrailMatcherGraphIndex,
        within toleranceMeters: Double,
        preferringWay preferredWayID: Int64?
    ) -> Int? {
        var best: (edgeIndex: Int, offRouteMeters: Double)?
        var preferred: (edgeIndex: Int, offRouteMeters: Double)?

        index.grid.forEachEdge(
            near: coordinate,
            within: toleranceMeters
        ) { edgeIndex in
            let endpoints = index.edgeEndpoints[edgeIndex]
            let projection = RouteGeometry.project(
                coordinate,
                onSegmentFrom: endpoints.start,
                to: endpoints.end
            )
            let offRouteMeters = projection.offRouteMeters
            guard offRouteMeters <= toleranceMeters else { return }
            if offRouteMeters < (best?.offRouteMeters ?? .infinity) {
                best = (edgeIndex, offRouteMeters)
            }
            if index.edges[edgeIndex].id.wayID == preferredWayID,
               offRouteMeters < (preferred?.offRouteMeters ?? .infinity) {
                preferred = (edgeIndex, offRouteMeters)
            }
        }

        guard let best else { return nil }
        if let preferred,
           preferred.offRouteMeters
           <= best.offRouteMeters + wayStickinessMeters { return preferred.edgeIndex }
        return best.edgeIndex
    }
}
