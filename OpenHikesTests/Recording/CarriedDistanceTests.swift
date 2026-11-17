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
//  and at the save, and still takes back what follows it.
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

    /// A loop 20 m across the middle, as a trail round a pond or a summit
    /// cairn is drawn: 90 legs of about 1.4 m.
    private let loop = RouteProfile(route: (0...90).map { step in
        let angle = Double(step) / 90 * 2 * .pi
        return RouteCoordinate(
            latitude: 47 + 20 * sin(angle) / RouteGeometry.metersPerDegreeLatitude,
            longitude: 12 + 20 * cos(angle) / (RouteGeometry.metersPerDegreeLatitude * cos(47 * .pi / 180))
        )
    })

    /// A walk that covered the whole of ``loop`` in five minutes: slow enough
    /// that half a minute of it never leaves a 15 m circle.
    private func loopWalk() -> TrailWalkRecord {
        var walk = TrailWalkRecord(hikeID: UUID(), routeDistanceMeters: loop.totalDistanceMeters, startedAt: start)
        for distance in loop.distances { walk.coverage.record(distance: distance) }
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
        let walk = loopWalk()
        let seed = try #require(RecordingSeed.carrying(walk, along: loop))
        #expect(seed.points.allSatisfy { $0.flags.contains(.carried) })

        let counted = replayed(seed.points)

        #expect(counted.distanceMeters.isApproximatelyEqual(to: walk.coverage.walkedMeters, absoluteTolerance: 0.5))
        #expect(!counted.isStationary)
    }

    @Test("the save counts it in full too")
    func theSaveCountsItInFull() throws {
        let walk = loopWalk()
        let seed = try #require(RecordingSeed.carrying(walk, along: loop))

        let prepared = try RecordingPreparation.prepare(points: seed.points, startedAt: seed.startedAt)

        #expect(prepared.distanceMeters.isApproximatelyEqual(to: walk.coverage.walkedMeters, absoluteTolerance: 0.5))
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
