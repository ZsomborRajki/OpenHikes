//
//  HikeWalkPhotoDirectionTests.swift
//  OpenHikesTests
//
//  Which way a walk's guess runs. A photograph with no position of its own is
//  placed by even progress through what the walk covered, and progress has a
//  direction: a walk from the route's stored end starts at the top of the
//  covered union and works down. Read as route order, it put a photograph
//  taken a kilometre from where the hiker set out a kilometre from where they
//  finished — mirrored within the stretch (#1040).
//
//  The walks here are real records, accrued match by match and closed into
//  the row the photo search reads, so the direction under test is the one
//  coverage actually stores.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Hike walk photo direction")
struct HikeWalkPhotoDirectionTests {
    /// 10:00 on the afternoon of the walk.
    private static let start = Date(timeIntervalSince1970: 1_750_000_000)
    private static let minute: TimeInterval = 60
    private static let routeMeters: Double = 4000

    /// A walk over `legs` in turn, a match every 50 m, between 10:00 and
    /// 10:00 plus `minutes`, closed into the stored row and read back as the
    /// photo search reads it. A leg that starts further than
    /// ``TrailWalkPolicy/gapBoundMeters`` from where the last one ended leaves
    /// a gap, as a lost signal does.
    private static func timeline(
        _ legs: [(from: Double, to: Double)],
        minutes: Double = 120
    ) throws -> HikeWalkPhotoTimeline {
        var record = TrailWalkRecord(hikeID: UUID(), routeDistanceMeters: routeMeters, startedAt: start)
        for leg in legs {
            let direction: Double = leg.to >= leg.from ? 1 : -1
            var distance = leg.from
            while direction * (leg.to - distance) > 0 {
                record.coverage.record(distance: distance)
                distance += direction * 50
            }
            record.coverage.record(distance: leg.to)
        }
        let walk = HikeWalk(
            closing: record,
            at: start.addingTimeInterval(minutes * minute),
            reason: .reachedEnd
        )
        return try #require(HikeWalkPhotoTimeline(
            startedAt: walk.startedAt,
            endedAt: walk.endedAt,
            coverage: walk.coverage
        ))
    }

    private static func distance(
        on timeline: HikeWalkPhotoTimeline,
        atMinute minutes: Double
    ) throws -> Double {
        try #require(timeline.distanceAlongRoute(at: start.addingTimeInterval(minutes * minute)))
    }

    /// The issue's own walk: 4 km stored A→B, followed from B to A between
    /// 10:00 and 12:00. At 10:30 the hiker was a kilometre from B.
    @Test("a walk from the stored end is placed from that end")
    func walkFromTheStoredEndRunsDown() throws {
        let timeline = try Self.timeline([(from: Self.routeMeters, to: 0)])

        #expect(timeline.walkedTowardsStart)
        #expect(try Self.distance(on: timeline, atMinute: 30).isApproximatelyEqual(
            to: 3000,
            absoluteTolerance: 1e-6
        ))
    }

    /// The control: the same trail walked the way it is stored is placed as
    /// it always was.
    @Test("a walk the stored way is placed as before")
    func walkTheStoredWayRunsUp() throws {
        let timeline = try Self.timeline([(from: 0, to: Self.routeMeters)])

        #expect(!timeline.walkedTowardsStart)
        #expect(try Self.distance(on: timeline, atMinute: 30).isApproximatelyEqual(
            to: 1000,
            absoluteTolerance: 1e-6
        ))
    }

    /// The grace at each end is the walk's own end nearest it: the photograph
    /// taken while the walk was being started is at B, where it started.
    @Test("the grace of a walk from the stored end is placed at its own ends")
    func graceFollowsTheWalksEnds() throws {
        let timeline = try Self.timeline([(from: 3000, to: 500)])

        #expect(try Self.distance(on: timeline, atMinute: -2).isApproximatelyEqual(
            to: 3000,
            absoluteTolerance: 1e-6
        ))
        #expect(try Self.distance(on: timeline, atMinute: 122).isApproximatelyEqual(
            to: 500,
            absoluteTolerance: 1e-6
        ))
    }

    /// Walked down, a gap is stepped over from the top: at three quarters of
    /// the clock the hiker has done 1,500 of their 2,000 covered metres, the
    /// whole upper kilometre and half the lower one.
    @Test("a walk from the stored end steps over its gap from the top")
    func gapIsSteppedOverFromTheTop() throws {
        let timeline = try Self.timeline([(from: 4000, to: 3000), (from: 1000, to: 0)])

        #expect(timeline.walkedTowardsStart)
        #expect(try Self.distance(on: timeline, atMinute: 90).isApproximatelyEqual(
            to: 500,
            absoluteTolerance: 1e-6
        ))
    }

    /// A match that lands a step behind the one before it is not a turn, so it
    /// cannot make a one-way walk into a walk both ways, in either direction.
    @Test("a step too short to be a turn does not change the direction")
    func shortStepBackIsNotATurn() throws {
        let step = TrailWalkPolicy.minimumTurnMeters / 2
        let forward = try Self.timeline([
            (from: 0, to: 2000), (from: 2000 - step, to: 4000),
        ])
        let back = try Self.timeline([
            (from: 4000, to: 2000), (from: 2000 + step, to: 0),
        ])

        #expect(!forward.walkedTowardsStart)
        #expect(back.walkedTowardsStart)
    }

    /// A walk both ways has no order the row can say, so it keeps the route's
    /// — the right answer for the usual out-and-back from the stored start.
    /// Out to 3 km and back to 1 km covers 0…3000, and a quarter of the way
    /// through is 750 m out.
    @Test("a walk both ways is placed in route order")
    func walkBothWaysKeepsRouteOrder() throws {
        let timeline = try Self.timeline([(from: 0, to: 3000), (from: 3000, to: 1000)])

        #expect(!timeline.walkedTowardsStart)
        #expect(try Self.distance(on: timeline, atMinute: 30).isApproximatelyEqual(
            to: 750,
            absoluteTolerance: 1e-6
        ))
    }
}
