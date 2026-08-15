//
//  TrailDifficultyBreakdown.swift
//  OpenHikes
//
//  How much of a route runs at each SAC difficulty grade, derived by projecting
//  the route onto the cached OSM trail graph and reading `sac_scale` off the
//  ways it lands on.
//

import CoreLocation
import Foundation

nonisolated struct TrailDifficultyBreakdown: Equatable, Sendable {
    nonisolated struct Share: Identifiable, Equatable, Sendable {
        var id: TrailDifficulty { difficulty }
        let difficulty: TrailDifficulty
        let meters: Double
        /// Portion of ``TrailDifficultyBreakdown/totalMeters``, in `0...1`.
        let fraction: Double
    }

    /// Every grade with a non-zero share, surveyed grades first and
    /// longest first within each group, so the leading entry answers
    /// "what was the dominant difficulty on this walk".
    let shares: [Share]
    /// Route length as measured by this breakdown — the sum of all shares,
    /// which keeps fractions adding up to exactly 1.
    let totalMeters: Double

    static let empty = Self(shares: [], totalMeters: 0)

    var isEmpty: Bool { shares.isEmpty }

    var dominant: Share? { shares.first }

    /// How much of the route OSM has actually graded.
    var surveyedFraction: Double {
        shares.reduce(0) { total, share in
            share.difficulty.isSurveyed ? total + share.fraction : total
        }
    }

    func meters(for difficulty: TrailDifficulty) -> Double {
        shares.first { $0.difficulty == difficulty }?.meters ?? 0
    }

    private init(shares: [Share], totalMeters: Double) {
        self.shares = shares
        self.totalMeters = totalMeters
    }

    init(metersByDifficulty: [TrailDifficulty: Double]) {
        let total = metersByDifficulty.values.reduce(0, +)
        guard total > 0 else {
            self = .empty
            return
        }
        totalMeters = total
        shares = metersByDifficulty
            .filter { _, meters in meters > 0 }
            .map { difficulty, meters in
                Share(
                    difficulty: difficulty,
                    meters: meters,
                    fraction: meters / total
                )
            }
            .sorted { lhs, rhs in
                if lhs.difficulty.isSurveyed != rhs.difficulty.isSurveyed { return lhs.difficulty.isSurveyed }
                if lhs.meters != rhs.meters { return lhs.meters > rhs.meters }
                // Among equal distances, easier grade first.
                return (TrailDifficulty.displayOrdering.firstIndex(of: lhs.difficulty) ?? 0)
                    < (TrailDifficulty.displayOrdering.firstIndex(of: rhs.difficulty) ?? 0)
            }
    }
}

// MARK: - Analysis

nonisolated enum TrailDifficultyAnalyzer {
    /// Inherits the same geometric constants as the surface analyzer — the
    /// same sampling density and tolerance are appropriate for both tags.
    static let defaultToleranceMeters = TrailSurfaceAnalyzer.defaultToleranceMeters
    static let samplingStepMeters = TrailSurfaceAnalyzer.samplingStepMeters
    static let wayStickinessMeters = TrailSurfaceAnalyzer.wayStickinessMeters
    static let maximumStepsPerSegment = TrailSurfaceAnalyzer.maximumStepsPerSegment
    private static let cancellationCheckInterval = 255

    /// Attributes every metre of `route` to a SAC difficulty grade.
    ///
    /// A stretch with no way beneath it is reported as ``TrailDifficulty/unmapped``.
    /// Ways that carry no `sac_scale` tag are reported as ``TrailDifficulty/unknown``
    /// — this is common for paths in lower terrain, where a mapper records a
    /// footway but not its grade.
    @concurrent
    static func breakdown(
        route: [RouteCoordinate],
        graph: TrailGraph,
        toleranceMeters: Double = defaultToleranceMeters
    ) async throws(CancellationError) -> TrailDifficultyBreakdown {
        assertOffMainThread(
            "Trail difficulty analysis must stay off the main thread"
        )
        guard route.count > 1, !graph.isEmpty else { return .empty }
        let index = TrailMatcherGraphIndex(graph: graph)
        guard !index.edges.isEmpty else { return .empty }

        var metersByDifficulty: [TrailDifficulty: Double] = [:]
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
                let sample = RouteGeometry.interpolate(
                    from: from,
                    to: to,
                    fraction: (Double(step) + 0.5) / Double(steps)
                )
                let edgeIndex = TrailSurfaceAnalyzer.nearestEdgeIndex(
                    to: sample,
                    in: index,
                    within: toleranceMeters,
                    preferringWay: previousWayID
                )
                let difficulty: TrailDifficulty
                if let edgeIndex {
                    let edge = index.edges[edgeIndex]
                    difficulty = TrailDifficulty(edge: edge)
                    previousWayID = edge.id.wayID
                } else {
                    difficulty = .unmapped
                    previousWayID = nil
                }
                metersByDifficulty[difficulty, default: 0] += stepMeters
            }
        }

        return TrailDifficultyBreakdown(metersByDifficulty: metersByDifficulty)
    }
}
