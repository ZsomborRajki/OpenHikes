//
//  TrailBreakdown.swift
//  OpenHikes
//
//  How much of a route runs in each category of some OSM tag, and the one walk
//  over the trail graph that measures it.
//
//  Surface and difficulty are the same measurement asked of two different tags:
//  project the route onto the cached graph, read a tag off the ways it lands
//  on, and total the metres per category. They were written twice — two
//  structurally identical value types and two sampling loops that matched each
//  other line for line — and the hazard in that is not size, it is drift: a fix
//  to the stickiness rule or the cancellation cadence lands in one copy and
//  quietly not in the other.
//
//  So the geometry lives here once and the categories supply only what
//  genuinely differs between them: how a way is classified, what "no way at
//  all" is called, and what order the results read best in.
//

import CoreLocation
import Foundation

/// A category a stretch of route can be attributed to by reading one OSM tag.
///
/// Conformers are ``TrailSurface`` and ``TrailDifficulty``. Everything a
/// breakdown needs from them is here; everything about *presenting* one — names,
/// colours, summaries — deliberately is not, because the analysis has no view
/// layer and should not gain one.
nonisolated protocol TrailCategory: Hashable, Sendable {
    /// The natural presentation order, which is also the tie-break between two
    /// categories covering exactly the same distance.
    static var displayOrdering: [Self] { get }
    /// What a stretch with no way beneath it is called. Reported rather than
    /// snapped to the nearest thing available — see
    /// ``TrailBreakdownAnalyzer/breakdown(of:route:graph:toleranceMeters:)``.
    static var unmapped: Self { get }
    /// Whether this category came from actual OSM tagging, as opposed to
    /// describing the absence of it.
    var isSurveyed: Bool { get }
    /// The category the tagging on `edge` puts a sample in.
    init(edge: TrailGraphEdge)
}

nonisolated extension TrailCategory {
    /// Position in ``displayOrdering``. Anything missing from it sorts last.
    var displayOrder: Int {
        Self.displayOrdering.firstIndex(of: self) ?? Self.displayOrdering.count
    }
}

/// How much of a route falls in each category of one tag.
nonisolated struct TrailBreakdown<Category: TrailCategory>: Equatable, Sendable {
    nonisolated struct Share: Identifiable, Equatable, Sendable {
        var id: Category { category }
        let category: Category
        let meters: Double
        /// Portion of ``TrailBreakdown/totalMeters``, in `0...1`.
        let fraction: Double
    }

    /// Every category with a non-zero share, surveyed ones first and longest
    /// first within each group, so the leading entry is the answer to "what did
    /// I mostly walk on".
    let shares: [Share]
    /// Route length as measured by this walk, which is the sum of the shares
    /// rather than ``Hike/distanceMeters`` — using the sum keeps the fractions
    /// adding up to exactly 1.
    let totalMeters: Double

    static var empty: Self { Self(shares: [], totalMeters: 0) }

    var isEmpty: Bool { shares.isEmpty }

    /// The leading share: the longest surveyed category, or — when nothing on
    /// this route was surveyed — the longest share of any kind. `nil` for an
    /// empty breakdown.
    var dominant: Share? { shares.first }

    /// How much of the route OSM actually describes. A low value means the
    /// percentages below it are drawn from a small sample and should be read
    /// as such — which is why the unsurveyed remainder is charted rather than
    /// quietly dropped.
    var surveyedFraction: Double {
        shares.reduce(0) { total, share in
            share.category.isSurveyed ? total + share.fraction : total
        }
    }

    func meters(for category: Category) -> Double {
        shares.first { $0.category == category }?.meters ?? 0
    }

    private init(shares: [Share], totalMeters: Double) {
        self.shares = shares
        self.totalMeters = totalMeters
    }

    init(metersByCategory: [Category: Double]) {
        let total = metersByCategory.values.reduce(0, +)
        guard total > 0 else {
            self = .empty
            return
        }
        totalMeters = total
        shares = metersByCategory
            .filter { _, meters in meters > 0 }
            .map { category, meters in
                Share(
                    category: category,
                    meters: meters,
                    fraction: meters / total
                )
            }
            .sorted { lhs, rhs in
                if lhs.category.isSurveyed != rhs.category.isSurveyed {
                    return lhs.category.isSurveyed
                }
                if lhs.meters != rhs.meters { return lhs.meters > rhs.meters }
                return lhs.category.displayOrder < rhs.category.displayOrder
            }
    }
}

/// The breakdown of a route by surface, derived from OSM `surface` tagging.
typealias TrailSurfaceBreakdown = TrailBreakdown<TrailSurface>
/// The breakdown of a route by SAC grade, derived from OSM `sac_scale` tagging.
typealias TrailDifficultyBreakdown = TrailBreakdown<TrailDifficulty>

// MARK: - Analysis

nonisolated enum TrailBreakdownAnalyzer {
    /// How far a sample may sit from a way before that way stops being a
    /// plausible explanation for it. An imported GPX can be a good 20 m off a
    /// correctly mapped trail under tree cover, and attributing a tag is a
    /// much cheaper claim than relocating a route.
    static let defaultToleranceMeters = 25.0
    /// Upper bound on the spacing between samples — a route segment shorter
    /// than this still contributes one. Small enough to catch the short paved
    /// connectors between trail sections, large enough that a five-hour track
    /// is a few thousand grid lookups rather than one per metre.
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

    /// Attributes every metre of `route` to a category of `categoryType`.
    ///
    /// This is a read-only measurement, not a match: it never moves the route,
    /// and a stretch with no way beneath it is reported as
    /// ``TrailCategory/unmapped`` rather than snapped to the nearest thing
    /// available. Running the full HMM matcher here would be both slower and
    /// less honest — it exists to decide where a walker *was*, and its answer
    /// for a leg it is unsure about is a straight line, which has no tagging.
    ///
    /// A way matched but carrying no tag of its own is the category's own
    /// business, not this function's: ``TrailSurface`` and ``TrailDifficulty``
    /// both report it as `unknown`, which is common for paths in lower terrain
    /// where a mapper records a footway but not its grade.
    @concurrent
    static func breakdown<Category: TrailCategory>(
        of categoryType: Category.Type,
        route: [RouteCoordinate],
        graph: TrailGraph,
        toleranceMeters: Double = defaultToleranceMeters
    ) async throws(CancellationError) -> TrailBreakdown<Category> {
        assertOffMainThread(
            "Trail breakdown analysis must stay off the main thread"
        )
        guard route.count > 1, !graph.isEmpty else { return .empty }
        let index = TrailMatcherGraphIndex(graph: graph)
        guard !index.edges.isEmpty else { return .empty }

        var metersByCategory: [Category: Double] = [:]
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
                // exactly on a junction where two differently tagged ways meet
                // and the choice between them is a coin toss.
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
                let category: Category
                if let edgeIndex {
                    let edge = index.edges[edgeIndex]
                    category = Category(edge: edge)
                    previousWayID = edge.id.wayID
                } else {
                    category = .unmapped
                    previousWayID = nil
                }
                metersByCategory[category, default: 0] += stepMeters
            }
        }

        return TrailBreakdown(metersByCategory: metersByCategory)
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
