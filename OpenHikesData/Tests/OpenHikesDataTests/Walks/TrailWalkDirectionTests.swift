//
//  TrailWalkDirectionTests.swift
//  OpenHikesDataTests
//
//  Which way a walk went along its trail. Coverage is the ground covered, and
//  it never cared which way: a walk from the stored end finishes like any
//  other. The climb does care — a hill walked down is a descent — so each
//  stretch is kept the way it was walked, in the same flat pairs, and the
//  union every other reader wants is unchanged (#993).
//

import Foundation
@testable import OpenHikesData
import RealModule
import Testing

@Suite("Trail walk direction")
struct TrailWalkDirectionTests {
    /// About 760 m rising a steady 100 m, a height every 15 m or so.
    private static let hill = RouteProfile(route: (0...50).map { index in
        RouteCoordinate(latitude: 47, longitude: 11 + Double(index) * 0.0002, elevation: 100 + Double(index) * 2)
    })

    /// Matches every `step` metres from `start` to `end`.
    private func walk(from start: Double, to end: Double, into coverage: inout TrailWalkCoverage, step: Double = 20) {
        var distance = start
        let direction: Double = end >= start ? 1 : -1
        while direction * (end - distance) > 0 {
            coverage.record(distance: distance)
            distance += direction * step
        }
        coverage.record(distance: end)
    }

    /// The coverage of matches at each of `indices` along ``hill`` in turn.
    private func walk(_ indices: some Sequence<Int>) -> TrailWalkCoverage {
        var coverage = TrailWalkCoverage()
        for index in indices {
            coverage.record(distance: Self.hill.distances[index])
        }
        return coverage
    }

    @Test("a stretch walked towards the stored start is kept apart from one walked towards the end")
    func directionsAreKeptApart() {
        var coverage = TrailWalkCoverage()
        walk(from: 1000, to: 600, into: &coverage)
        coverage.breakContinuity()
        walk(from: 0, to: 300, into: &coverage)

        #expect(coverage.walkedTowardsEnd == [0...300])
        #expect(coverage.walkedTowardsStart == [600...1000])
        #expect(coverage.ranges == [0...300, 600...1000])
        #expect(coverage.coveredMeters.isApproximatelyEqual(to: 700, absoluteTolerance: 1e-9))
    }

    /// Covered once, walked twice: the union is the ground, and each way
    /// keeps its own copy of it.
    @Test("there and back is covered once and kept once each way")
    func thereAndBackIsKeptEachWay() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 400, into: &coverage)
        walk(from: 400, to: 200, into: &coverage)

        #expect(coverage.walkedTowardsEnd == [0...400])
        #expect(coverage.walkedTowardsStart == [200...400])
        #expect(coverage.ranges == [0...400])
        #expect(coverage.coveredMeters.isApproximatelyEqual(to: 400, absoluteTolerance: 1e-9))
        #expect(coverage.walkedMeters.isApproximatelyEqual(to: 600, absoluteTolerance: 1e-9))
    }

    /// Each way is a union of its own, so walking back over ground walked
    /// back before adds nothing to it.
    @Test("each way merges as a union of its own")
    func eachWayMerges() {
        var coverage = TrailWalkCoverage()
        walk(from: 800, to: 500, into: &coverage)
        coverage.breakContinuity()
        walk(from: 300, to: 100, into: &coverage)
        #expect(coverage.walkedTowardsStart == [100...300, 500...800])

        coverage.breakContinuity()
        walk(from: 600, to: 200, into: &coverage)
        #expect(coverage.walkedTowardsStart == [100...800])
        #expect(coverage.walkedTowardsEnd.isEmpty)
    }

    /// The row a walk closes into stores the same bytes the record held, and
    /// those bytes say which way each stretch went.
    @Test("stored pairs keep the way each stretch was walked")
    func storedPairsKeepTheirWay() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 400, into: &coverage)
        walk(from: 400, to: 200, into: &coverage)
        coverage.breakContinuity()
        walk(from: 900, to: 700, into: &coverage)

        #expect(coverage.intervals == [0, 400, 400, 200, 900, 700])
        let rebuilt = TrailWalkCoverage(
            intervals: coverage.intervals,
            furthestDistanceMeters: coverage.furthestDistanceMeters
        )
        #expect(rebuilt == coverage.withoutContinuity)
        #expect(rebuilt.walkedTowardsStart == [200...400, 700...900])
    }

    /// A pair written low to high is the way the route's distances run, which
    /// is every row a recording writes of its own route.
    @Test("a pair written low to high was walked towards the end")
    func ascendingPairsWentTowardsTheEnd() {
        let coverage = TrailWalkCoverage(intervals: [0, 500, 400, 900], furthestDistanceMeters: 0)

        #expect(coverage.walkedTowardsEnd == [0...900])
        #expect(coverage.walkedTowardsStart.isEmpty)
    }

    @Test("a walk up the hill climbs it")
    func walkUpClimbs() throws {
        let climb = try #require(Self.hill.climb(walking: walk(0...50)))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 100, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
    }

    @Test("a walk down the hill descends it")
    func walkDownDescends() throws {
        let climb = try #require(Self.hill.climb(walking: walk((0...50).reversed())))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 100, absoluteTolerance: 0.001))
    }

    @Test("up to the middle and back climbs that half and descends it")
    func thereAndBackClimbsBothWays() throws {
        let climb = try #require(Self.hill.climb(walking: walk(Array(0...25) + Array((0...24).reversed()))))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 50, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 50, absoluteTolerance: 0.001))
    }

    /// Matches are not smoothed, and two matchers feed them, so a walk that
    /// only ever went one way still has the odd match land behind the one
    /// before it. That step is covered, and it is no turn.
    @Test("a match that lands behind the one before it is no turn")
    func stepBackIsNoTurn() throws {
        let up = walk(Array(0...30) + [27] + Array(33...50))
        #expect(up.walkedTowardsStart.isEmpty)
        #expect(up.ranges == [0...Self.hill.distances[50]])
        #expect(up.walkedMeters.isApproximatelyEqual(to: up.coveredMeters, absoluteTolerance: 1e-9))
        let climb = try #require(Self.hill.climb(walking: up))
        #expect(climb.gainMeters.isApproximatelyEqual(to: 100, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))

        let down = walk(Array((20...50).reversed()) + [23] + Array((0...17).reversed()))
        #expect(down.walkedTowardsEnd.isEmpty)
        let descent = try #require(Self.hill.climb(walking: down))
        #expect(descent.gainMeters.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(descent.lossMeters.isApproximatelyEqual(to: 100, absoluteTolerance: 0.001))
    }

    /// Only a longer stretch leaves a short one out, so a there and back too
    /// short to be a turn either way is still climbed both ways.
    @Test("a short there and back keeps both ways")
    func shortThereAndBackKeepsBothWays() throws {
        let coverage = walk([0, 1, 2, 3, 2, 1, 0])
        let stretch = 0...Self.hill.distances[3]
        #expect(stretch.upperBound < TrailWalkPolicy.minimumTurnMeters)
        #expect(coverage.walkedTowardsEnd == [stretch])
        #expect(coverage.walkedTowardsStart == [stretch])
        #expect(coverage.walkedMeters.isApproximatelyEqual(to: 2 * stretch.upperBound, absoluteTolerance: 1e-9))
        let climb = try #require(Self.hill.climb(walking: coverage))
        #expect(climb.gainMeters.isApproximatelyEqual(to: 6, absoluteTolerance: 0.001))
        #expect(climb.lossMeters.isApproximatelyEqual(to: 6, absoluteTolerance: 0.001))
    }

    @Test("a walk with no stretch along any heights has no climb to say")
    func noStretchNoClimb() {
        #expect(Self.hill.climb(walking: TrailWalkCoverage()) == nil)
        #expect(Self.hill.climb(walking: walk([50])) == nil)
    }
}

private extension TrailWalkCoverage {
    /// This coverage as a stored row reads it back: a row keeps the union and
    /// the furthest point, never where the last match landed.
    var withoutContinuity: Self {
        var copy = self
        copy.breakContinuity()
        return copy
    }
}
