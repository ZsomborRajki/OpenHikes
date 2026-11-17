//
//  WalkRecordingSeedTests.swift
//  OpenHikesTests
//
//  What a walk along a trail hands a recording that takes over from it: the
//  trail's own line along the stretches it covered, clocked from the walk's
//  own figures.
//
//  A walk keeps no fixes, so every point here is made. What these hold is
//  that the points say no more than the walk knew — the ground it covered,
//  in the time it was active, with nothing across a stretch it did not walk —
//  and that a recording reads them back as that: each test that is about a
//  figure replays the points through the accumulator a recording counts
//  with.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Walk recording seed")
struct WalkRecordingSeedTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)
    /// Twenty points due north, 56 m apart and 8 m higher each, then back
    /// down beside them. Only the way out is walked here.
    private let profile = RouteProfile(route: Fixture.outAndBackRoute)
    private let route = Fixture.outAndBackRoute

    // MARK: Fixtures

    /// A walk that began at ``start`` and matched at each of the route's
    /// points `indices` names in turn, a minute apart from `offset` on.
    private func walk(
        matchingAt indices: [Int],
        from offset: TimeInterval = 0,
        continuing earlier: TrailWalkRecord? = nil
    ) -> TrailWalkRecord {
        var record = earlier ?? TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: start
        )
        for (step, index) in indices.enumerated() {
            record.coverage.record(distance: profile.distances[index])
            record.lastFollowedDistanceMeters = profile.distances[index]
            record.lastMatchedAt = start.addingTimeInterval(offset + Double(step) * 60)
        }
        return record
    }

    /// What a recording counts of `points`: its distance and its active time.
    private func replayed(_ points: [RecordingPoint]) -> RecordingDistanceAccumulator {
        var accumulator = RecordingDistanceAccumulator()
        for point in points { accumulator.append(point) }
        return accumulator
    }

    private func isAt(_ point: RecordingPoint?, _ index: Int) -> Bool {
        guard let point else { return false }
        return RouteGeometry.distanceMeters(from: point.coordinate, to: route[index].clCoordinate) < 0.5
    }

    // MARK: One stretch

    @Test("a stretch walked along the trail is the trail's line, from the walk's start to its last match")
    func oneStretchIsTheTrailsLine() throws {
        let seed = try #require(RecordingSeed.carrying(walk(matchingAt: Array(0...6)), along: profile))

        #expect(seed.startedAt == start)
        #expect(isAt(seed.points.first, 0))
        #expect(isAt(seed.points.last, 6))
        // To the instant, at both ends: a walk a recording's clock covers
        // all but a few ulps of still counts in the library's totals.
        #expect(seed.points.first?.timestamp == start)
        #expect(seed.points.last?.timestamp == start.addingTimeInterval(360))
        #expect(seed.points.allSatisfy { !$0.flags.contains(.resumed) }, "nothing interrupted it")

        let counted = replayed(seed.points)
        #expect(counted.distanceMeters.isApproximatelyEqual(to: profile.distances[6], absoluteTolerance: 1))
        #expect(counted.recordedDuration.isApproximatelyEqual(to: 360, absoluteTolerance: 0.001))
    }

    /// The save drops a point stamped like the one before it, and reads a
    /// long or slow leg as ground the recording has no evidence across.
    @Test("every carried point is later than the last, and no leg is long enough to read as a gap")
    func pointsAreOrderedAndDense() throws {
        let seed = try #require(RecordingSeed.carrying(walk(matchingAt: Array(0...6)), along: profile))

        for (previous, next) in zip(seed.points, seed.points.dropFirst()) {
            #expect(next.timestamp > previous.timestamp)
            #expect(next.timestamp.timeIntervalSince(previous.timestamp) <= RecordingSeed.maximumLegSeconds + 0.001)
            #expect(!TrailMatcher.needsDistanceEvidence(from: previous, to: next))
        }
    }

    @Test("a long straight leg of a drawn trail is carried as points close enough to follow")
    func longLegsAreFilledIn() throws {
        // Two points a kilometre apart, as a drawn trail's line can run.
        let straight = RouteProfile(route: [
            RouteCoordinate(latitude: 47.63, longitude: 12.86),
            RouteCoordinate(latitude: 47.639, longitude: 12.86),
        ])
        var record = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: straight.totalDistanceMeters,
            startedAt: start
        )
        for (step, distance) in [0.0, 400, 800].enumerated() {
            record.coverage.record(distance: distance)
            record.lastMatchedAt = start.addingTimeInterval(Double(step) * 300)
        }

        let seed = try #require(RecordingSeed.carrying(record, along: straight))

        for (previous, next) in zip(seed.points, seed.points.dropFirst()) {
            let leg = RouteGeometry.distanceMeters(from: previous.coordinate, to: next.coordinate)
            #expect(leg <= RecordingSeed.maximumLegMeters + 0.5)
        }
        #expect(replayed(seed.points).distanceMeters.isApproximatelyEqual(to: 800, absoluteTolerance: 1))
    }

    @Test("the trail's heights come along, read between its points")
    func heightsComeAlong() throws {
        let seed = try #require(RecordingSeed.carrying(walk(matchingAt: Array(0...6)), along: profile))

        #expect(seed.points.first?.elevation?.isApproximatelyEqual(to: 600, absoluteTolerance: 0.01) == true)
        #expect(seed.points.last?.elevation?.isApproximatelyEqual(to: 648, absoluteTolerance: 0.01) == true)
        let heights = seed.points.compactMap(\.elevation)
        #expect(heights.count == seed.points.count)
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 }, "a steady climb, with no step back")
        // Six steps of eight metres, less whatever the last of it leaves
        // inside the recording's deadband.
        let gain = try #require(replayed(seed.points).elevationGainMeters)
        #expect((44...48.5).contains(gain))
    }

    // MARK: Which way

    /// The direction a trail is stored in is its importer's. A walk down it
    /// is carried down it.
    @Test("a stretch walked towards the trail's start is carried that way round")
    func aStretchWalkedBackIsCarriedBack() throws {
        let seed = try #require(RecordingSeed.carrying(walk(matchingAt: Array((0...6).reversed())), along: profile))

        #expect(isAt(seed.points.first, 6))
        #expect(isAt(seed.points.last, 0))
        #expect(seed.points.allSatisfy { !$0.flags.contains(.resumed) })
    }

    @Test("out along the trail and back along it is one line, turned where the walk turned")
    func outAndBackIsOneLine() throws {
        let record = walk(matchingAt: Array(0...10) + Array((4...9).reversed()))

        let seed = try #require(RecordingSeed.carrying(record, along: profile))

        #expect(isAt(seed.points.first, 0))
        #expect(isAt(seed.points.last, 4))
        #expect(seed.points.allSatisfy { !$0.flags.contains(.resumed) }, "a turn is not a break")
        let walked = profile.distances[10] + (profile.distances[10] - profile.distances[4])
        #expect(replayed(seed.points).distanceMeters.isApproximatelyEqual(to: walked, absoluteTolerance: 1))
    }

    // MARK: Breaks and pauses

    @Test("ground the walk did not cover is a break, with no distance across it")
    func aGapIsABreak() throws {
        var record = walk(matchingAt: Array(0...4))
        // What an accepted fix off the route does, or a pause.
        record.coverage.breakContinuity()
        record = walk(matchingAt: Array(8...12), from: 300, continuing: record)

        let seed = try #require(RecordingSeed.carrying(record, along: profile))

        let resumed = seed.points.filter { $0.flags.contains(.resumed) }
        #expect(resumed.count == 1)
        #expect(isAt(resumed.first, 8), "the point that opens the second stretch says so")
        let covered = profile.distances[4] + (profile.distances[12] - profile.distances[8])
        #expect(replayed(seed.points).distanceMeters.isApproximatelyEqual(to: covered, absoluteTolerance: 1))
    }

    @Test("a pause sits in the break it left, and is not time the recording was recording")
    func aPauseSitsInItsBreak() throws {
        var record = walk(matchingAt: Array(0...4))
        record.pause(at: start.addingTimeInterval(240))
        record.resume(at: start.addingTimeInterval(840))
        record = walk(matchingAt: Array(8...12), from: 840, continuing: record)

        let seed = try #require(RecordingSeed.carrying(record, along: profile))

        let opening = try #require(seed.points.firstIndex { $0.flags.contains(.resumed) })
        let across = seed.points[opening].timestamp.timeIntervalSince(seed.points[opening - 1].timestamp)
        #expect(across.isApproximatelyEqual(to: 600, absoluteTolerance: 0.001), "the ten minutes it was paused for")
        #expect(seed.points.last?.timestamp == start.addingTimeInterval(1080))
        #expect(replayed(seed.points).recordedDuration.isApproximatelyEqual(to: 480, absoluteTolerance: 0.001))
    }

    /// A pause leaves no break when the first match after it lands on ground
    /// already covered, which a hiker who paused and stood still does half
    /// the time. The clock still has to reach from the walk's start to its
    /// last match, or the library would count the walk's first minutes twice.
    @Test("a pause that left no break is a wait at the first point, so the clock still starts with the walk")
    func aPauseWithNoBreakWaitsAtTheStart() throws {
        var record = walk(matchingAt: Array(0...4))
        record.pause(at: start.addingTimeInterval(240))
        record.resume(at: start.addingTimeInterval(840))
        record = walk(matchingAt: Array(4...8), from: 840, continuing: record)
        #expect(record.coverage.ranges.count == 1)

        let seed = try #require(RecordingSeed.carrying(record, along: profile))

        #expect(seed.points.first?.timestamp == start)
        #expect(isAt(seed.points.first, 0))
        #expect(seed.points[1].flags.contains(.resumed))
        #expect(isAt(seed.points[1], 0), "it waited where it set off from")
        let waited = seed.points[1].timestamp.timeIntervalSince(start)
        #expect(waited.isApproximatelyEqual(to: 600, absoluteTolerance: 0.001), "the ten minutes it was paused for")
        #expect(seed.points.last?.timestamp == start.addingTimeInterval(1080))
        let counted = replayed(seed.points)
        #expect(counted.recordedDuration.isApproximatelyEqual(to: 480, absoluteTolerance: 0.001))
        #expect(counted.distanceMeters.isApproximatelyEqual(to: profile.distances[8], absoluteTolerance: 1))
    }

    /// A walk's active clock runs on while its hiker is off the route. Shared
    /// out over the little it covered, the points would read as standing
    /// still, and a recording takes that distance back.
    @Test("hours off the route do not slow the covered ground to a standstill")
    func aLongClockDoesNotReadAsStandingStill() throws {
        var record = walk(matchingAt: Array(0...4))
        record.lastMatchedAt = start.addingTimeInterval(3 * 3600)

        let seed = try #require(RecordingSeed.carrying(record, along: profile))

        let counted = replayed(seed.points)
        #expect(counted.distanceMeters.isApproximatelyEqual(to: profile.distances[4], absoluteTolerance: 1))
        #expect(!counted.isStationary)
        #expect(
            seed.points.last?.timestamp == start.addingTimeInterval(3 * 3600),
            "and the clock still reaches the walk's last match"
        )
    }

    // MARK: Nothing to carry

    @Test("a walk that covered nothing carries nothing")
    func nothingCoveredCarriesNothing() {
        let unmatched = TrailWalkRecord(
            hikeID: UUID(),
            routeDistanceMeters: profile.totalDistanceMeters,
            startedAt: start
        )
        #expect(RecordingSeed.carrying(unmatched, along: profile) == nil)
        let oneMatch = walk(matchingAt: [3])
        #expect(RecordingSeed.carrying(oneMatch, along: profile) == nil, "one match is a place, not a stretch")
    }

    // MARK: As a recording saves it

    @Test("the save keeps the carried line, its break and its length")
    func theSaveKeepsWhatWasCarried() throws {
        var record = walk(matchingAt: Array(0...4))
        record.coverage.breakContinuity()
        record = walk(matchingAt: Array(8...12), from: 300, continuing: record)
        let seed = try #require(RecordingSeed.carrying(record, along: profile))

        let prepared = try RecordingPreparation.prepare(points: seed.points, startedAt: seed.startedAt)

        #expect(prepared.route.count == seed.points.count)
        #expect(prepared.route.filter { $0.boundary == .paused }.count == 1)
        let covered = profile.distances[4] + (profile.distances[12] - profile.distances[8])
        #expect(prepared.routeLengthMeters.isApproximatelyEqual(to: covered, absoluteTolerance: 1))
        #expect(RouteProfile(route: prepared.route).pauseDistances.count == 1)
    }
}
