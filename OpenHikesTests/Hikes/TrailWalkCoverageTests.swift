//
//  TrailWalkCoverageTests.swift
//  OpenHikesTests
//
//  What a walk's completion figure means. Coverage rather than position: the
//  union of along-route intervals consecutive matches spanned, so a walker
//  who opens the app halfway round an out-and-back and walks to the end reads
//  50%, walking a section twice adds nothing, and a lost signal does not
//  paint the valley in between as walked.
//
//  The four numbers `TrailWalkPolicy` proposes are pinned here, not measured:
//  a change to one of them is a change to these tests first.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail walk coverage")
struct TrailWalkCoverageTests {
    private static let routeLength: Double = 2000

    /// Matches every `step` metres from `start` to `end`, the way a walker
    /// produces them.
    private func walk(from start: Double, to end: Double, into coverage: inout TrailWalkCoverage, step: Double = 20) {
        var distance = start
        let direction: Double = end >= start ? 1 : -1
        while direction * (end - distance) > 0 {
            coverage.record(distance: distance)
            distance += direction * step
        }
        coverage.record(distance: end)
    }

    /// The case the whole figure exists for. A walker who opens the app at the
    /// turn of an out-and-back and walks home reads half, where position along
    /// the route would read all of it.
    @Test("a walk from the turn of an out-and-back covers half of it")
    func startingAtTheTurnCoversHalf() throws {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        let total = profile.totalDistanceMeters
        var coverage = TrailWalkCoverage()
        for index in (profile.coordinates.count / 2)..<profile.coordinates.count {
            coverage.record(distance: profile.distances[index])
        }
        let fraction = try #require(coverage.fractionComplete(routeDistanceMeters: total))
        #expect(abs(fraction - 0.5) < 0.03, "read \(fraction), position would have read 1.0")
        #expect(abs(coverage.furthestDistanceMeters - total) < 1, "the furthest point is still the end")
    }

    /// Walking a section twice — wandering back to a viewpoint — adds nothing.
    @Test("a backtrack adds nothing to the union")
    func backtrackAddsNothing() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 400, into: &coverage)
        let before = coverage.coveredMeters
        walk(from: 400, to: 200, into: &coverage)
        walk(from: 200, to: 400, into: &coverage)
        #expect(coverage.coveredMeters == before)
        #expect(coverage.coveredMeters == 400)
        #expect(coverage.ranges.count == 1, "the union stays one interval")
    }

    /// A re-acquisition after a lost signal must not paint the ground between
    /// two matches as walked.
    @Test("a jump wider than the gap bound is not bridged")
    func wideJumpIsNotBridged() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 200, into: &coverage)
        coverage.record(distance: 800)
        #expect(coverage.coveredMeters == 200, "the 600 m between 200 and 800 was never seen")
        #expect(coverage.furthestDistanceMeters == 800, "but the walker did get there")
        // The next match continues from where they landed, not from before
        // the gap.
        coverage.record(distance: 820)
        #expect(coverage.coveredMeters == 220)
        #expect(coverage.ranges.count == 2)
    }

    @Test("a jump at the gap bound is bridged, one metre past it is not")
    func gapBoundIsInclusive() {
        var bridged = TrailWalkCoverage()
        bridged.record(distance: 0)
        bridged.record(distance: TrailWalkPolicy.gapBoundMeters)
        #expect(bridged.coveredMeters == TrailWalkPolicy.gapBoundMeters)

        var broken = TrailWalkCoverage()
        broken.record(distance: 0)
        broken.record(distance: TrailWalkPolicy.gapBoundMeters + 1)
        #expect(broken.coveredMeters == 0)
    }

    /// Two stretches walked apart merge the moment a third joins them.
    @Test("stretches merge when a walk joins them")
    func stretchesMerge() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 300, into: &coverage)
        coverage.record(distance: 900)
        walk(from: 900, to: 1200, into: &coverage)
        #expect(coverage.ranges.count == 2)
        // Back along the road, on the trail this time.
        walk(from: 1200, to: 300, into: &coverage)
        #expect(coverage.ranges.count == 1)
        #expect(coverage.coveredMeters == 1200)
    }

    @Test("the fraction clamps and refuses a zero-length route")
    func fractionClampsAndRefusesZero() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 2500, into: &coverage)
        #expect(coverage.fractionComplete(routeDistanceMeters: Self.routeLength) == 1)
        #expect(coverage.fractionComplete(routeDistanceMeters: 0) == nil)
        #expect(TrailWalkCoverage().fractionComplete(routeDistanceMeters: Self.routeLength) == 0)
    }

    /// The end is reached at the threshold and not one step before it, on
    /// both halves of the test: coverage, and proximity to the route's end.
    @Test("reaching the end fires at the threshold and not one step before")
    func reachedEndThreshold() {
        let proximity = TrailWalkPolicy.reachedEndProximityMeters
        let fraction = TrailWalkPolicy.reachedEndFraction
        #expect(TrailWalkPolicy.hasReachedEnd(coveredFraction: fraction, distanceToEndMeters: proximity))
        #expect(!TrailWalkPolicy.hasReachedEnd(coveredFraction: fraction - 0.001, distanceToEndMeters: proximity))
        #expect(!TrailWalkPolicy.hasReachedEnd(coveredFraction: fraction, distanceToEndMeters: proximity + 1))
        #expect(TrailWalkPolicy.hasReachedEnd(coveredFraction: 1, distanceToEndMeters: 0))
    }

    /// The same rule over a real record: a walker who reaches the far end of
    /// the out-and-back — half the route — has not reached the end, and one
    /// who walks the whole thing has.
    @Test("a record reaches the end only once it has covered the route")
    func recordReachesTheEnd() {
        let profile = RouteProfile(route: Fixture.outAndBackRoute)
        var record = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: .now
        )
        let turn = profile.coordinates.count / 2
        for index in 0...turn {
            record.coverage.record(distance: profile.distances[index])
        }
        #expect(!record.reachesEnd(atMatch: profile.distances[turn]), "the turn is not the end")
        for index in turn..<(profile.coordinates.count - 1) {
            record.coverage.record(distance: profile.distances[index])
            #expect(!record.reachesEnd(atMatch: profile.distances[index]), "not at point \(index)")
        }
        let last = profile.distances[profile.coordinates.count - 1]
        record.coverage.record(distance: last)
        #expect(record.reachesEnd(atMatch: last))
    }

    /// Opening a trail at the trailhead for a look leaves no row behind.
    @Test("a walk under the minimum is not kept")
    func minimumCoverage() {
        var short = TrailWalkCoverage()
        walk(from: 0, to: TrailWalkPolicy.minimumCoverageMeters - 1, into: &short, step: 10)
        #expect(!short.meetsMinimum)

        var kept = TrailWalkCoverage()
        walk(from: 0, to: TrailWalkPolicy.minimumCoverageMeters, into: &kept, step: 10)
        #expect(kept.meetsMinimum)
    }

    /// The flat pairs a row stores rebuild the same union, and a row edited
    /// by hand into overlapping pairs still reads as one.
    @Test("stored pairs rebuild the union")
    func storedPairsRebuild() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 300, into: &coverage)
        coverage.record(distance: 900)
        walk(from: 900, to: 1000, into: &coverage)
        let rebuilt = TrailWalkCoverage(
            intervals: coverage.intervals,
            furthestDistanceMeters: coverage.furthestDistanceMeters
        )
        #expect(rebuilt.ranges == coverage.ranges)
        #expect(rebuilt.furthestDistanceMeters == 1000)

        let overlapping = TrailWalkCoverage(intervals: [0, 500, 400, 900, 950, 940], furthestDistanceMeters: 0)
        #expect(overlapping.ranges == [0...900, 940...950])
        #expect(overlapping.furthestDistanceMeters == 950)
    }
}
