//
//  CarriedDistanceTests.swift
//  OpenHikesTests
//
//  Ground a walk along a trail had covered before a recording took over from
//  it is counted in full — see ``RecordingPointFlags/carried``. The trail's
//  line bends where the trail does, and is clocked at the pace the walk's own
//  time gives it, so a tight bend can stay inside the small area the
//  recording reads as a hiker standing still. These hold that the rule which
//  hands back a standing hiker's GPS wander leaves that ground alone, live
//  and at the save, and still takes back what follows it; and that the
//  moving clock, which reads no flag, is given a pace it counts as walking.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Carried distance")
struct CarriedDistanceTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// A loop of `radius` metres, as a trail round a summit or a pond is
    /// drawn: 90 legs.
    private static func loop(radius: Double) -> RouteProfile {
        RouteProfile(route: (0...90).map { step in
            let angle = Double(step) / 90 * 2 * .pi
            return RouteCoordinate(
                latitude: 47 + radius * sin(angle) / RouteGeometry.metersPerDegreeLatitude,
                longitude: 12 + radius * cos(angle) / (RouteGeometry.metersPerDegreeLatitude * cos(47 * .pi / 180))
            )
        })
    }

    /// Round a summit cairn, 10 m across: half a minute of it at the slowest
    /// carried pace stays inside the 15 m a recording reads as a hiker
    /// standing still.
    private let cairn = Self.loop(radius: 5)
    /// Round a pond, 40 m across: tight enough that ground clocked at the
    /// stillness rate itself read as stopped there, and loose enough that the
    /// slowest carried pace does not.
    private let pond = Self.loop(radius: 20)
    /// 600 m due north, a point every 5 m.
    private let line = RouteProfile(route: (0...120).map { step in
        RouteCoordinate(latitude: 47 + Double(step) * 5 / RouteGeometry.metersPerDegreeLatitude, longitude: 12)
    })

    /// A walk that covered the whole of ``cairn`` in five minutes.
    private func cairnWalk() -> TrailWalkRecord {
        var walk = TrailWalkRecord(hikeID: UUID(), routeDistanceMeters: cairn.totalDistanceMeters, startedAt: start)
        for distance in cairn.distances { walk.coverage.record(distance: distance) }
        walk.lastMatchedAt = start.addingTimeInterval(300)
        return walk
    }

    private func replayed(_ points: [RecordingPoint]) -> RecordingDistanceAccumulator {
        var accumulator = RecordingDistanceAccumulator()
        for point in points { accumulator.append(point) }
        return accumulator
    }

    private func point(
        north meters: Double,
        at seconds: TimeInterval,
        flags: RecordingPointFlags = []
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: 47.63 + meters / RouteGeometry.metersPerDegreeLatitude,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(seconds),
            horizontalAccuracy: 8,
            flags: flags
        )
    }

    @Test("carried ground round a tight bend counts in full, as the walk covered it")
    func aTightBendIsCountedInFull() throws {
        let walk = cairnWalk()
        let seed = try #require(RecordingSeed.carrying(walk, along: cairn))
        #expect(seed.points.allSatisfy { $0.flags.contains(.carried) })

        let counted = replayed(seed.points)

        #expect(counted.distanceMeters.isApproximatelyEqual(to: walk.coverage.walkedMeters, absoluteTolerance: 0.5))
        #expect(!counted.isStationary)
    }

    @Test("the save counts it in full too")
    func theSaveCountsItInFull() throws {
        let walk = cairnWalk()
        let seed = try #require(RecordingSeed.carrying(walk, along: cairn))

        let prepared = try RecordingPreparation.prepare(points: seed.points, startedAt: seed.startedAt)

        #expect(prepared.distanceMeters.isApproximatelyEqual(to: walk.coverage.walkedMeters, absoluteTolerance: 0.5))
    }

    /// The moving clock weighs net displacement and reads no flag, so carried
    /// ground has to be clocked clear of the rate it calls stopped — here at
    /// the slowest pace a carried point is given, which a walk this slow for
    /// its ground is held to.
    @Test(
        "carried ground keeps its moving time, round a bend and along a straight line",
        arguments: [false, true]
    )
    func carriedGroundKeepsItsMovingTime(straight: Bool) throws {
        let profile = straight ? line : pond
        var walk = TrailWalkRecord(hikeID: UUID(), routeDistanceMeters: profile.totalDistanceMeters, startedAt: start)
        for distance in profile.distances { walk.coverage.record(distance: distance) }
        // Four times as long as the ground took at the slowest pace.
        let walking = profile.totalDistanceMeters / RecordingSeed.slowestWalkingSpeed
        walk.lastMatchedAt = start.addingTimeInterval(4 * walking)
        let seed = try #require(RecordingSeed.carrying(walk, along: profile))

        let live = replayed(seed.points)
        let prepared = try RecordingPreparation.prepare(points: seed.points, startedAt: seed.startedAt)
        var saved = MovingTimeAccumulator()
        for coordinate in prepared.route { saved.record(coordinate) }

        #expect(live.movingSeconds >= walking * 0.95)
        #expect(saved.seconds >= walking * 0.95)
        #expect(saved.seconds <= walking + 0.001, "and the wait before it is not walking")
    }

    /// Only the carried legs are left alone: standing about after them is
    /// weighed from where they end, and taken back as any other wander is.
    @Test("standing still after carried ground is still taken back, and the carried ground is not")
    func standingAfterCarriedGroundIsTakenBack() {
        let carried = (0...10).map { step in
            point(north: Double(step) * 20, at: Double(step) * 20, flags: step == 0 ? [] : .carried)
        }
        // Ten minutes of jitter a few metres either side of the last of them.
        let standing = (1...60).map { step in
            point(north: 200 + Double((step % 3) - 1) * 3, at: 200 + Double(step) * 10)
        }

        let counted = replayed(carried + standing)

        #expect(counted.isStationary)
        #expect(counted.distanceMeters >= 200 - 0.5)
        #expect(counted.distanceMeters < 205)
    }

    /// The save's matcher can lay a matched path between two carried points,
    /// and the bend it adds there is the walk's ground as much as the line's.
    @Test("points matched between two carried points are carried, and between a carried point and a fix are not")
    func matchingKeepsTheMark() {
        let first = point(north: 0, at: 0, flags: .carried)
        let second = point(north: 40, at: 40, flags: .carried)
        let fix = point(north: 80, at: 80)
        // A bend about 7 m east of the straight line, `meters` north.
        func bend(_ meters: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: 47.63 + meters / RouteGeometry.metersPerDegreeLatitude, longitude: 12.8601)
        }

        let carriedLeg = TrailMatcher.recordingPoints(along: [bend(10), bend(30)], from: first, to: second)
        let liveLeg = TrailMatcher.recordingPoints(along: [bend(50), bend(70)], from: second, to: fix)

        #expect(carriedLeg.count == 4)
        #expect(carriedLeg.allSatisfy { $0.flags.contains(.carried) })
        #expect(liveLeg.count == 4)
        #expect(liveLeg.dropFirst().allSatisfy { !$0.flags.contains(.carried) })
    }
}
