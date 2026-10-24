//
//  LibraryTotalsWalkDirectionTests.swift
//  OpenHikesTests
//
//  What a followed walk adds to the library's climb: what it climbed itself,
//  each stretch the way it was walked, and not the trail's climb in
//  proportion to what it covered (#1039). The share card has read a walk's
//  climb that way since #1012; *Totals* now reads the same figure, and
//  *Steepest* spreads it over the length walked, each stretch once per way.
//
//  Run through the real sweep rather than through hand-built facts, because
//  the climb and the length walked are measured there, along the route each
//  walk was walked on.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@Suite("Library totals by the way a walk went")
struct LibraryTotalsWalkDirectionTests {
    /// Four kilometres due north, climbing 400 m over the first half and
    /// flat over the second, never descending.
    private static let route: [RouteCoordinate] = {
        let steps = 40
        return (0...steps).map { step in
            RouteCoordinate(
                latitude: 47.0 + Double(step) * 0.0009,
                longitude: 11.0,
                elevation: 1000 + Double(min(step, steps / 2)) * 20
            )
        }
    }()

    private static let profile = RouteProfile(route: route)
    /// Where the climb tops out, as the profile measures it.
    private static let top = profile.distances[20]
    private static let total = profile.totalDistanceMeters
    private static let walkedAt = Date(timeIntervalSince1970: 1_790_000_000)

    /// Three kilometres recorded a week before the walk, climbing 450 m and
    /// never descending: 15%, steeper than the there and back's 10% and less
    /// steep than the 20% its climb over the ground covered once would read.
    private static func recording() -> Hike {
        let recordedAt = walkedAt.addingTimeInterval(-7 * 86_400)
        let track = (0...30).map { step in
            RouteCoordinate(
                latitude: 47.0 + Double(step) * 0.0009,
                longitude: 12.0,
                elevation: 1000 + Double(step) * 15,
                timestamp: recordedAt.addingTimeInterval(Double(step) * 60)
            )
        }
        let meters = RouteProfile(route: track).totalDistanceMeters
        return Hike(title: "Recorded", distanceMeters: meters, date: recordedAt, route: track)
    }

    /// The library's totals with the trail, one walk along it whose
    /// stretches are written the way they were walked, and `others`.
    private static func totals(
        walking intervals: [Double],
        beside others: [Hike] = []
    ) async throws -> LibraryTotals {
        let container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let hike = Hike(title: "Ridge", distanceMeters: total, route: route)
        context.insert(hike)
        for other in others {
            context.insert(other)
        }
        let coverage = TrailWalkCoverage(intervals: intervals, furthestDistanceMeters: 0)
        context.insert(HikeWalk(
            hikeID: hike.id,
            startedAt: walkedAt,
            endedAt: walkedAt.addingTimeInterval(3600),
            activeSeconds: 3600,
            coveredIntervals: coverage.intervals,
            furthestDistanceMeters: coverage.furthestDistanceMeters,
            routeDistanceMeters: total,
            endReason: .ended,
            routeRevision: TrailWalkRecord.routeRevision(of: hike.route)
        ))
        try context.save()
        let read = try await LibraryTotalsSweep.read(from: container)
        return LibraryTotals(hikes: read.hikes, walks: read.walks, year: 2026)
    }

    /// Down the whole of a trail that only ever climbs: the share card reads
    /// no ascent, and neither may the year's climb or the steepest record.
    @Test("a whole walk down a trail climbs nothing, and is never the steepest")
    func aWalkDownClimbsNothing() async throws {
        let totals = try await Self.totals(walking: [Self.total, 0])

        #expect(totals.allTime.outings == 1)
        #expect(totals.allTime.distanceMeters.isApproximatelyEqual(to: Self.total, absoluteTolerance: 1e-6))
        #expect(totals.allTime.climbMeters == 0, "not the trail's 400 m")
        #expect(totals.allTime.outingsWithoutClimb == 0, "it climbed nothing, which is not unknown")
        #expect(totals.steepest == nil, "an outing that climbed nothing is not steep")
    }

    /// Half the trail's length, and none of its climb.
    @Test("a walk over the flat half of a trail climbs nothing, not half the trail's climb")
    func theFlatHalfClimbsNothing() async throws {
        let totals = try await Self.totals(walking: [Self.top, Self.total])

        #expect(totals.allTime.climbMeters == 0)
        #expect(totals.steepest == nil)
    }

    /// Up the climb and back down it: the climb once, over the ground
    /// covered once — and as steep as the four kilometres walked, not as the
    /// two covered.
    @Test("a walk up and back down the climb climbs it once, as steep as the ground it walked")
    func aThereAndBackClimbsItOnce() async throws {
        let totals = try await Self.totals(walking: [0, Self.top, Self.top, 0])
        let climb = try #require(Self.profile.climb(from: 0, to: Self.top))

        #expect(climb.gainMeters.isApproximatelyEqual(to: 400, absoluteTolerance: 1))
        #expect(totals.allTime.climbMeters.isApproximatelyEqual(to: climb.gainMeters, absoluteTolerance: 1e-6))
        #expect(totals.allTime.distanceMeters.isApproximatelyEqual(to: Self.top, absoluteTolerance: 1e-6))
        let steepest = try #require(totals.steepest)
        #expect(steepest.climbMeters == totals.allTime.climbMeters)
        #expect(
            steepest.gradient.isApproximatelyEqual(to: 0.10, absoluteTolerance: 0.001),
            "400 m over the 4 km walked, not over the 2 km covered"
        )
    }

    /// The record is the steepest outing, and a walk there and back is no
    /// steeper for having covered its ground once.
    @Test("a steeper recording keeps the record from a walk there and back")
    func aSteeperRecordingKeepsTheRecord() async throws {
        let recording = Self.recording()
        let totals = try await Self.totals(walking: [0, Self.top, Self.top, 0], beside: [recording])

        #expect(totals.allTime.outings == 2)
        let steepest = try #require(totals.steepest)
        #expect(steepest.hikeID == recording.id)
        #expect(steepest.gradient.isApproximatelyEqual(to: 0.15, absoluteTolerance: 0.001))
    }

    /// The walk the share card has always measured this way.
    @Test("a walk up the whole trail climbs what the trail does")
    func aWalkUpClimbsTheTrail() async throws {
        let totals = try await Self.totals(walking: [0, Self.total])
        let climb = try #require(Self.profile.climb(from: 0, to: Self.total))

        #expect(totals.allTime.climbMeters.isApproximatelyEqual(to: climb.gainMeters, absoluteTolerance: 1e-6))
        #expect(totals.steepest?.distanceMeters == totals.allTime.distanceMeters)
    }
}
