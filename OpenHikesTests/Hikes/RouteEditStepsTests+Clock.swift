//
//  RouteEditStepsTests+Clock.swift
//  OpenHikesTests
//
//  What steps leave of the recording's own walk: a pause a straightened
//  stretch draws over still leaves its time out, and the time a removed
//  stretch takes off is the same whether its step was saved before a step
//  that clears the line's clock or with it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension RouteEditStepsTests {
    /// The recording's own walk along `route`, `activeSeconds` of it walked.
    func recordedWalk(
        for hike: Hike,
        along route: [RouteCoordinate],
        activeSeconds: TimeInterval,
        in context: ModelContext
    ) throws -> HikeWalk {
        let length = route.lengthMeters
        let walk = HikeWalk(
            hikeID: hike.id,
            startedAt: Line.start,
            endedAt: route.last?.timestamp ?? Line.start,
            activeSeconds: activeSeconds,
            coveredIntervals: [0, length],
            furthestDistanceMeters: length,
            routeDistanceMeters: length,
            endReason: .recorded,
            routeRevision: TrailWalkRecord.routeRevision(of: route)
        )
        context.insert(walk)
        walk.hike = hike
        try context.save()
        return walk
    }

    /// How much longer than a minute the gap before the sixth point is.
    private static let pauseSeconds: TimeInterval = 600

    /// Eleven points a minute apart, but for an eleven-minute pause before
    /// the sixth: nine minutes walked.
    static let pausedRoute: [RouteCoordinate] = (0...10).map { index in
        var walked = point(index)
        if index >= 5 { walked.timestamp = walked.timestamp?.addingTimeInterval(pauseSeconds) }
        if index == 5 { walked.boundary = .paused }
        return walked
    }

    @Test("a stretch straightened across a pause leaves the walk the time it was walked")
    func straightenedAcrossAPause() async throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.pausedRoute)
        let walked = RouteTrim.recordedSeconds(of: Self.pausedRoute)
        #expect(walked == 9 * Line.secondsPerPoint, "precondition: the pause is not walking")
        let walk = try recordedWalk(for: hike, along: Self.pausedRoute, activeSeconds: walked, in: context)
        let distances = RouteTrim.distances(along: Self.pausedRoute)
        let session = await visit(hike, in: context)

        await session.beginStretch()
        session.move(.start, to: distances[3])
        session.move(.end, to: distances[7])
        await session.straightenStretch()
        #expect(await session.save(to: destination(for: hike, in: context)))

        #expect(walk.activeSeconds == walked)
        let paused = hike.route.contains(where: \.isPauseBoundary)
        #expect(paused, "the pause is still on the line")
    }

    @Test("a stretch removed comes off the walk's time once, whether saved before the line was turned round or with it")
    func removedThenTurned() async throws {
        let context = try Fixture.modelContext()
        let removed = Line.walkSeconds - 3 * Line.secondsPerPoint

        let together = try savedHike(in: context)
        let walkedTogether = try recordedWalk(
            for: together,
            along: Self.route,
            activeSeconds: Line.walkSeconds,
            in: context
        )
        let both = await visit(together, in: context)
        await removeTheMiddle(in: both)
        await both.reverse()
        #expect(await both.save(to: destination(for: together, in: context)))
        #expect(walkedTogether.activeSeconds == removed)

        let apart = try savedHike(in: context)
        let walkedApart = try recordedWalk(for: apart, along: Self.route, activeSeconds: Line.walkSeconds, in: context)
        let first = await visit(apart, in: context)
        await removeTheMiddle(in: first)
        #expect(await first.save(to: destination(for: apart, in: context)))
        let second = await visit(apart, in: context)
        await second.reverse()
        #expect(await second.save(to: destination(for: apart, in: context)))
        #expect(walkedApart.activeSeconds == removed)

        // Both taken back on a later visit: the time comes back once.
        let again = await visit(together, in: context)
        await again.undo()
        await again.undo()
        #expect(again.steps.isEmpty)
        #expect(await again.save(to: destination(for: together, in: context)))
        #expect(walkedTogether.activeSeconds == Line.walkSeconds)
    }

    private func removeTheMiddle(in session: RouteTrimSession) async {
        await session.beginStretch()
        session.move(.start, to: Self.distances[3])
        session.move(.end, to: Self.distances[6])
        await session.takeOutStretch()
    }
}
