//
//  LibraryTotalsRouteEditTests.swift
//  OpenHikesTests
//
//  What *Edit Route* does to the library's totals (#912).
//
//  A drawn trail can be redrawn under walks already made along it, and those
//  walks are kept as history — but what one of them climbed was a fact about
//  the line it walked, which the trail no longer draws. So a walk along a line
//  its trail has been redrawn from since keeps its outing, its distance and
//  its time, adds no climb, and is never the Highest or Steepest record: the
//  new line's figures would be a claim about a walk nobody made.
//
//  This is the issue's own probe, run through the real save and the real
//  sweep rather than through hand-built facts, because the defect lived in
//  the join between the two: each was right on its own.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

@MainActor
@Suite("Library totals after Edit Route")
struct LibraryTotalsRouteEditTests {
    private enum Line {
        static let longitude: Double = 12.86
        static let start: Double = 47.63
        static let middle: Double = 47.65
        /// Where the redrawn trail goes on to.
        static let end: Double = 47.67
    }

    private enum Heights {
        static let original: [Double] = [600, 700]
        static let originalClimb: Double = 100
        static let originalTop: Double = 700
        static let redrawn: [Double] = [600, 1100, 1600]
    }

    private static let year = 2026
    /// A day in ``year``.
    private static let walkedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private static let hour: TimeInterval = 3600

    private static func draft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes {
            draft.append(CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude))
        }
        return draft
    }

    /// Heights read for exactly `draft`'s line, as the maker would have them.
    private static func heights(for draft: TrailDraft, of metres: [Double]) -> RouteHeightSamples {
        let route = draft.routeCoordinates
        return RouteHeightSamples(
            routePointCount: route.count,
            indexes: Array(route.indices),
            coordinates: route,
            heights: metres
        )
    }

    private static func totals(in container: ModelContainer) async throws -> LibraryTotals {
        let read = try await LibraryTotalsSweep.read(from: container)
        return LibraryTotals(hikes: read.hikes, walks: read.walks, year: year)
    }

    /// The whole of one walk along `hike` as it is drawn now.
    private static func walk(along hike: Hike) -> HikeWalk {
        HikeWalk(
            hikeID: hike.id,
            startedAt: walkedAt,
            endedAt: walkedAt.addingTimeInterval(hour),
            activeSeconds: hour,
            coveredIntervals: [0, hike.distanceMeters],
            furthestDistanceMeters: hike.distanceMeters,
            routeDistanceMeters: hike.distanceMeters,
            endReason: .ended,
            routeRevision: TrailWalkRecord.routeRevision(of: hike.route)
        )
    }

    @Test("a walk along the line a trail was redrawn from keeps its distance and loses its climb")
    func redrawnTrailWithholdsTheWalksClimb() async throws {
        let container = try Fixture.modelContainer()
        let context = ModelContext(container)
        let original = Self.draft([Line.start, Line.middle])
        let hike = try #require(
            TrailDraftSave.hike(
                from: original,
                named: "Audit trail",
                into: context,
                heights: Self.heights(for: original, of: Heights.original)
            ).hike
        )
        let walk = Self.walk(along: hike)
        context.insert(walk)
        walk.hike = hike
        try context.save()

        let before = try await Self.totals(in: container)
        #expect(before.allTime.climbMeters.isApproximatelyEqual(to: Heights.originalClimb, absoluteTolerance: 1e-6))
        #expect(before.highest?.highestMeters == Heights.originalTop)
        #expect(before.steepest?.hikeID == hike.id)
        #expect(before.allTime.outingsWithoutClimb == 0)

        let redrawn = Self.draft([Line.start, Line.middle, Line.end])
        let saved = TrailDraftSave.update(
            hike,
            from: redrawn,
            openedWith: [],
            into: context,
            heights: Self.heights(for: redrawn, of: Heights.redrawn)
        )
        #expect(saved.hike?.id == hike.id)
        let current = TrailWalkRecord.routeRevision(of: hike.route)
        #expect(!walk.isAlong(revision: current), "the walk was along the line the trail used to draw")

        let after = try await Self.totals(in: container)
        #expect(after.allTime.outings == 1, "the walk still happened")
        #expect(after.allTime.distanceMeters == before.allTime.distanceMeters)
        #expect(after.allTime.movingSeconds == Self.hour)
        #expect(after.allTime.climbMeters == 0, "not the redrawn line's climb")
        #expect(after.allTime.outingsWithoutClimb == 1)
        #expect(after.longest?.hikeID == hike.id)
        #expect(after.highest == nil, "not the redrawn line's top")
        #expect(after.steepest == nil)
    }
}
