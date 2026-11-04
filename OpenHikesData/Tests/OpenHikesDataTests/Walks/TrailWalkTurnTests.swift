//
//  TrailWalkTurnTests.swift
//  OpenHikesDataTests
//
//  Which way a walk is going now, read off its matches in the order they
//  landed. The stretches keep which way each one was walked and not when, so
//  one union is both a walk on its way up and a walk on its way back down,
//  and the time left times one end of the trail or the other on the answer
//  (#1195).
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Trail walk turns")
struct TrailWalkTurnTests {
    private static let turn = TrailWalkPolicy.minimumTurnMeters

    /// The coverage of a match at each of `distances`, in order.
    private func matched(_ distances: Double...) -> TrailWalkCoverage {
        var coverage = TrailWalkCoverage()
        for distance in distances {
            coverage.record(distance: distance)
        }
        return coverage
    }

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

    @Test("a walk has no way to go until its matches have moved a turn's length")
    func noWayBeforeTheDeadband() {
        #expect(TrailWalkCoverage().direction == nil)
        #expect(matched(1000).direction == nil)
        #expect(matched(1000, 1040, 1010, 1000 + Self.turn - 1).direction == nil)
        #expect(matched(1000, 960, 1000 - Self.turn + 1).direction == nil)
    }

    @Test("a turn's length exactly is enough, as it is for a stretch")
    func theDeadbandIsInclusive() {
        #expect(matched(1000, 1000 + Self.turn).direction == .towardsEnd)
        #expect(matched(1000, 1000 - Self.turn).direction == .towardsStart)
    }

    /// From either end, and from the middle, where the nearer end says
    /// nothing about where the hiker set off from.
    @Test("a walk goes the way it set off", arguments: [
        (0.0, 400.0, TrailWalkDirection.towardsEnd),
        (6000.0, 5600.0, TrailWalkDirection.towardsStart),
        (3000.0, 3400.0, TrailWalkDirection.towardsEnd),
        (3000.0, 2600.0, TrailWalkDirection.towardsStart),
    ])
    func aWalkGoesTheWayItSetOff(start: Double, end: Double, way: TrailWalkDirection) {
        var coverage = TrailWalkCoverage()
        walk(from: start, to: end, into: &coverage)
        #expect(coverage.direction == way)
    }

    /// Each one lands behind the one before it, and none of them is a turn,
    /// because each is measured from the furthest the walk has got.
    @Test("a match behind the one before it is no turn, however often it happens", arguments: [1.0, -1.0])
    func gpsBacksteps(way: Double) {
        let expected: TrailWalkDirection = way > 0 ? .towardsEnd : .towardsStart
        var coverage = TrailWalkCoverage()
        walk(from: 3000, to: 3000 + way * 300, into: &coverage)
        for offset in [260.0, 300, 330, 270, 340, 400, 350, 410] {
            coverage.record(distance: 3000 + way * offset)
            #expect(coverage.direction == expected, "at \(offset)")
        }
    }

    /// No one step is a turn's length. Together they are, and a hiker turned
    /// round on a slow fix rate is still turned round.
    @Test("steps too short to be a turn add up to one")
    func smallStepsAddUp() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 300, into: &coverage)
        coverage.record(distance: 270)
        coverage.record(distance: 240)
        #expect(coverage.direction == .towardsEnd)
        coverage.record(distance: 300 - Self.turn)
        #expect(coverage.direction == .towardsStart)
    }

    @Test("a sustained turn is believed, each way and back again")
    func sustainedTurnsBothWays() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 1000, into: &coverage)
        #expect(coverage.direction == .towardsEnd)

        coverage.record(distance: 1000 - Self.turn + 1)
        #expect(coverage.direction == .towardsEnd, "not yet")
        coverage.record(distance: 1000 - Self.turn)
        #expect(coverage.direction == .towardsStart)

        walk(from: 900, to: 500, into: &coverage)
        #expect(coverage.direction == .towardsStart)

        coverage.record(distance: 500 + Self.turn - 1)
        #expect(coverage.direction == .towardsStart, "not yet")
        coverage.record(distance: 500 + Self.turn)
        #expect(coverage.direction == .towardsEnd)
    }

    @Test("a walk from the stored end that turns is believed too")
    func aReversedWalkTurns() {
        var coverage = TrailWalkCoverage()
        walk(from: 6000, to: 4000, into: &coverage)
        #expect(coverage.direction == .towardsStart)
        walk(from: 4000, to: 4100, into: &coverage)
        #expect(coverage.direction == .towardsEnd)
    }

    /// The issue's point: one union, one position, opposite ways.
    @Test("the same ground and the same position can be going either way")
    func theUnionCannotSay() {
        var turned = TrailWalkCoverage()
        walk(from: 0, to: 8000, into: &turned)
        walk(from: 8000, to: 6500, into: &turned)

        var onward = TrailWalkCoverage()
        walk(from: 0, to: 8000, into: &onward)
        walk(from: 8000, to: 6000, into: &onward)
        walk(from: 6000, to: 6500, into: &onward)

        #expect(turned.ranges == onward.ranges)
        #expect(turned.lastMatchedDistance == onward.lastMatchedDistance)
        #expect(turned.direction == .towardsStart)
        #expect(onward.direction == .towardsEnd)
    }

    /// A pause or an accepted fix off the route says the hiker did not walk
    /// the stretch between, so landing behind it says nothing about which way
    /// they are going. The first match after it is where a turn counts from.
    @Test("a break keeps the way, and a turn counts from where the walk came back")
    func aBreakKeepsTheWay() {
        var coverage = TrailWalkCoverage()
        walk(from: 0, to: 1000, into: &coverage)

        coverage.breakContinuity()
        #expect(coverage.direction == .towardsEnd)
        coverage.record(distance: 400)
        #expect(coverage.direction == .towardsEnd, "600 m behind, and not walked")

        coverage.record(distance: 400 - Self.turn + 1)
        #expect(coverage.direction == .towardsEnd)
        coverage.record(distance: 400 - Self.turn)
        #expect(coverage.direction == .towardsStart)
    }

    /// The gap bound refuses the ground between, not the fact of having got
    /// there: every step of a significant-change feed can be past it, and a
    /// walk in a pocket still has somewhere it is going.
    @Test("a match past the gap bound covers nothing and still says which way")
    func aJumpStillSaysWhichWay() {
        let coverage = matched(5000, 4400, 3800)
        #expect(coverage.coveredMeters == 0)
        #expect(coverage.direction == .towardsStart)
    }

    /// What a relaunch reads: everything the last write held, the furthest
    /// the walk had got included. So a turn begun in the fixes that write
    /// missed counts from there rather than starting again.
    @Test("the way and what a turn counts from come back with the record")
    func theWaySurvivesTheRecord() throws {
        var record = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: 6000,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        walk(from: 0, to: 1000, into: &record.coverage)

        var restored = try JSONDecoder().decode(TrailWalkRecord.self, from: JSONEncoder().encode(record))

        #expect(restored == record)
        #expect(restored.coverage.direction == .towardsEnd)
        restored.coverage.record(distance: 1000 - Self.turn)
        #expect(restored.coverage.direction == .towardsStart)
    }
}
