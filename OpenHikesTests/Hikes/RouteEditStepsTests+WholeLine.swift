//
//  RouteEditStepsTests+WholeLine.swift
//  OpenHikesTests
//
//  *Edit Route* on the whole line — turned round, closed, doubled back, a
//  loop begun somewhere else — and how steps sit with the rest of the
//  editor: the answers to the sections stand under them, and *Revert to
//  Original* leaves every one of them out.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing

extension RouteEditStepsTests {
    // MARK: The whole line

    @Test("a line turned round and saved keeps its ground, its walk's time and the day it was walked")
    func turnedRound() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let date = hike.date
        let session = await visit(hike, in: context)

        await session.reverse()
        #expect(await session.save(to: destination(for: hike, in: context)))

        #expect(hike.route.map(\.latitude) == Self.route.reversed().map(\.latitude))
        #expect(hike.route.allSatisfy { $0.timestamp == nil })
        #expect(hike.date == date)
        #expect(hike.distanceMeters.isApproximatelyEqual(to: Self.distances[10], absoluteTolerance: 0.1))
        #expect(hike.routeEdit?.routeSteps == [.reverse])

        let again = await visit(hike, in: context)
        await again.undo()
        #expect(again.line?.route == Self.route)
        #expect(again.hasChanges)
        #expect(await again.save(to: destination(for: hike, in: context)))
        #expect(hike.route == Self.route)
        #expect(!hike.hasOriginalRoute, "every step taken back is the original")
    }

    @Test("a line is closed and doubled back, and a loop begun where its start handle stands")
    func closingDoublingAndStarting() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)
        #expect(!session.returnsToItsStart)
        #expect(!session.canStartLoopAtCut)

        await session.goOutAndBack()
        #expect(session.steps == [.outAndBack])
        #expect(session.returnsToItsStart)
        #expect(session.totalMeters.isApproximatelyEqual(to: Self.distances[10] * 2, absoluteTolerance: 0.1))
        await session.undo()

        await session.closeLoop()
        #expect(session.steps == [.closeLoop(.straight)], "with no router the way home is straight")
        #expect(session.line?.route.count == Self.route.count + 1)
        await session.undo()

        let routed = await visit(hike, in: context, router: DetourRouter())
        await routed.closeLoop()
        #expect(routed.steps.first?.pathCoordinateCount == 3, "the router's way home, its two ends included")
    }

    @Test("a loop is begun where its start handle stands, and what the handle cut goes on after the end")
    func aLoopBegunAtItsCut() async throws {
        let context = try Fixture.modelContext()
        let loop = Fixture.loopRoute
        let round = Fixture.hike(in: context, route: loop)
        try context.save()
        let session = await visit(round, in: context)
        let length = session.totalMeters
        #expect(session.line?.shape == .loop)
        #expect(!session.canStartLoopAtCut, "the handle has not been moved yet")

        session.move(.start, to: length / 4)
        #expect(session.canStartLoopAtCut)
        await session.startLoopAtCut()

        #expect(session.steps == [.startAt(length / 4)], "not a cut, so it is not kept as one")
        #expect(session.totalMeters.isApproximatelyEqual(to: length, absoluteTolerance: 0.5))
        #expect(session.trim == nil)
        #expect(!session.canStartLoopAtCut)
    }

    // MARK: With the rest

    @Test("an answer stands once a step is made on the line it drew")
    func answersStandUnderSteps() async throws {
        let context = try Fixture.modelContext()
        let assembly = RouteAssembly(
            pieces: [.kept(0...3), .check(1), .kept(6...10)],
            checks: [RouteCheck(id: 1, kind: .snapped, savedChoice: .matched, savedRange: 3...6, rawRange: 3...6)]
        )
        let recorded = Fixture.hike(in: context, route: Self.route)
        recorded.rawRoute = Self.route.map { fix in
            RouteCoordinate(latitude: fix.latitude, longitude: fix.longitude + 0.0001, timestamp: fix.timestamp)
        }
        recorded.routeEdit = RouteEdit(assembly: assembly)
        try context.save()
        let session = await visit(recorded, in: context)

        await session.reverse()
        await session.choose(.gps, forCheck: 1)

        #expect(session.checks.first?.choice == .matched)
        #expect(session.line?.checkRanges.isEmpty == true, "a step moves the ground a section stood on")

        await session.undo()
        await session.choose(.gps, forCheck: 1)
        #expect(session.checks.first?.choice == .gps)
    }

    @Test("Revert to Original leaves every step out")
    func revertingSteps() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)
        await session.goOutAndBack()
        await session.save(to: destination(for: hike, in: context))
        #expect(hike.route.count == Self.route.count * 2 - 1)

        #expect(session.revert(in: destination(for: hike, in: context)))

        #expect(hike.route == Self.route)
        #expect(hike.routeEditData == nil, "a hike with nothing left to remember keeps no record")
    }
}
