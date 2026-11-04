//
//  HikeWalkPhotoTimelineOrderTests.swift
//  OpenHikesTests
//
//  The order a hike's walks come back in for a photo search: oldest first,
//  and the same on every read (#1317).
//
//  A plan's ``HikePhotoSearchPlan/Fingerprint`` holds the walks in this order,
//  and the picker and Find Photos each go on until the fingerprint reads as
//  itself. The relationship hands its rows in no order of its own: the main
//  context hands them as they were added, and a context reading the store
//  hands them another way. Two walks that started at the same instant, left
//  in its order, read one way on the main actor and the other in the context
//  a search reads from, and the plan built in one reads as obsolete in the
//  other.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Hike walk photo timeline order")
struct HikeWalkPhotoTimelineOrderTests {
    /// An id whose order against another is plain to read.
    private static func id(_ digit: Int) throws -> UUID {
        try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000\(digit)"))
    }

    private static var routeMeters: Double {
        RouteProfile(route: PhotoDiscoveryFixture.unstampedRoute).totalDistanceMeters
    }

    /// A finished walk along the fixture route, between two moments in route
    /// steps. Walks that differ only in their end are walks a plan can tell
    /// apart, which is what makes their order matter.
    @discardableResult private static func addWalk(
        to hike: Hike,
        in context: ModelContext,
        id: UUID,
        steps: ClosedRange<Double>
    ) -> HikeWalk {
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: PhotoDiscoveryFixture.date(atStep: steps.lowerBound),
            endedAt: PhotoDiscoveryFixture.date(atStep: steps.upperBound),
            activeSeconds: (steps.upperBound - steps.lowerBound) * PhotoDiscoveryFixture.stepSeconds,
            coveredIntervals: [0, routeMeters / 2],
            furthestDistanceMeters: routeMeters / 2,
            routeDistanceMeters: routeMeters,
            endReason: .ended,
            routeRevision: PhotoDiscoveryFixture.routeRevision,
            id: id
        )
        context.insert(walk)
        walk.hike = hike
        return walk
    }

    /// The ends a hike's walks come back with, which says their order since
    /// the walks below differ in nothing else.
    private static func ends(of timelines: [HikeWalkPhotoTimeline]) -> [Date] {
        timelines.map(\.endedAt)
    }

    /// The contract, read whichever way the relationship was handed them.
    @Test("walks that started at the same instant come back in id order", arguments: [false, true])
    func tieIsBrokenByID(lowerAddedFirst: Bool) throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        let lower = try (id: Self.id(1), endStep: 9.0)
        let higher = try (id: Self.id(2), endStep: 12.0)
        for walk in lowerAddedFirst ? [lower, higher] : [higher, lower] {
            Self.addWalk(to: hike, in: context, id: walk.id, steps: 0...walk.endStep)
        }

        #expect(Self.ends(of: hike.walkPhotoTimelines) == [
            PhotoDiscoveryFixture.date(atStep: lower.endStep),
            PhotoDiscoveryFixture.date(atStep: higher.endStep),
        ])
    }

    /// The relationship is handed the same two walks the other way round, as
    /// another read of it may hand them, and the hike's walks still read as
    /// themselves.
    @Test("a hike's tied walks read the same however the relationship hands them")
    func tiedWalksReadAsThemselves() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        try Self.addWalk(to: hike, in: context, id: Self.id(1), steps: 0...9)
        try Self.addWalk(to: hike, in: context, id: Self.id(2), steps: 0...12)
        let before = hike.photoSearchSource.fingerprint
        let handed = try #require(hike.walks).map(\.id)

        hike.walks = hike.walks?.reversed()

        #expect(try #require(hike.walks).map(\.id) == handed.reversed(), "precondition: handed the other way")
        #expect(hike.photoSearchSource.fingerprint == before)
    }

    /// The bug where it happens. The same two walks, read where a photo search
    /// reads them, in a context of its own from the store, came back the other
    /// way from the main context's, so the two fingerprints differed.
    @Test("a hike's tied walks read the same in a search's own context")
    func tiedWalksReadAsThemselvesOffTheMainContext() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        try Self.addWalk(to: hike, in: context, id: Self.id(2), steps: 0...12)
        try Self.addWalk(to: hike, in: context, id: Self.id(1), steps: 0...9)
        try context.save()

        let read = HikePhotoSearchPlan.SourceRead(hike)
        let source = try #require(read.source(fetch: HikePhotoSearchPlan.SourceRead.fetchHike))

        #expect(source.fingerprint == hike.photoSearchSource.fingerprint)
    }

    /// What the tie-break must not reach: walks that started apart still come
    /// oldest first, whatever their ids.
    @Test("walks that started apart come back oldest first, whatever their ids")
    func startStillComesFirst() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        try Self.addWalk(to: hike, in: context, id: Self.id(1), steps: 100...109)
        try Self.addWalk(to: hike, in: context, id: Self.id(2), steps: 0...9)

        #expect(hike.walkPhotoTimelines.map(\.startedAt) == [
            PhotoDiscoveryFixture.date(atStep: 0),
            PhotoDiscoveryFixture.date(atStep: 100),
        ])
    }
}
