//
//  RouteEditStepsTests+Ground.swift
//  OpenHikesTests
//
//  A step is made on the ground it was worked out on, or not at all: a path
//  that comes back after a handle moved is dropped, nothing else changes the
//  line while a step is under way, a pause at the edge of a stretch stays a
//  pause, a step that would change nothing is not made, and the gray cover
//  hides every stretch of the hike's own line the new one no longer draws
//  the same way. And the whole-route menu is offered what fits the line, and
//  wakes only when that changes.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

/// A router that answers only once a suite lets it, so a handle can be
/// moved while a path is being found. Its answer is the straight leg,
/// snapped.
nonisolated private final class HeldRouter: TrailLegRouting {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Whether a question is waiting for its answer.
    var isAsked: Bool { state.withLock { !$0.waiting.isEmpty } }

    @concurrent
    func route(_ ends: TrailLegEnds) async -> TrailLegRoute? {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { held in
                if !held.isOpen { held.waiting.append(continuation) }
                return held.isOpen
            }
            if isOpen { continuation.resume() }
        }
        return TrailLegRoute(coordinates: [ends.start, ends.end], distanceMeters: 0, snap: .snapped)
    }

    func answer() {
        let waiting = state.withLock { held in
            held.isOpen = true
            defer { held.waiting = [] }
            return held.waiting
        }
        waiting.forEach { $0.resume() }
    }
}

extension RouteEditStepsTests {
    // MARK: A path for other ground

    @Test("a way home found after the end handle moved is dropped, and the cut stays where it was moved")
    func aWayHomeForAnEndThatMoved() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let router = HeldRouter()
        let session = await visit(hike, in: context, router: router)

        let closing = Task { await session.closeLoop() }
        await settleDelegateHop(until: "the way home is asked for") { router.isAsked }
        session.move(.end, to: Self.distances[8])
        router.answer()
        await closing.value

        #expect(session.steps.isEmpty)
        #expect(session.trim == 0...Self.distances[8])
        #expect(!session.isRouting)
        #expect(session.line?.route == Self.route)
    }

    @Test("a pull is made on the line it took hold of, or not at all")
    func aPullOnLineThatMoved() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let via = CLLocationCoordinate2D(
            latitude: Line.latitude + 4.5 * Line.spacing,
            longitude: Line.longitude + Line.detourOffset / 2
        )
        let stretch = Self.distances[3]...Self.distances[6]

        let straight = await visit(hike, in: context)
        let held = straight.stepGround
        straight.move(.start, to: Self.distances[1])
        #expect(await straight.reroute(stretch, through: via, on: held) == false)
        #expect(straight.steps.isEmpty)

        let router = HeldRouter()
        let routed = await visit(hike, in: context, router: router)
        let pulling = Task { await routed.reroute(stretch, through: via) }
        await settleDelegateHop(until: "the way through the spot is asked for") { router.isAsked }
        routed.move(.start, to: Self.distances[1])
        router.answer()
        #expect(await pulling.value == false)
        #expect(routed.steps.isEmpty)
        #expect(routed.startMeters == Self.distances[1])
    }

    // MARK: Nothing to make

    @Test("the whole line picked out is not taken out")
    func theWholeLineIsNotRemoved() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)
        await session.beginStretch()
        #expect(!session.picksWholeLine)

        session.move(.start, to: 0)
        session.move(.end, to: session.totalMeters)
        #expect(session.picksWholeLine)
        await session.takeOutStretch()

        #expect(session.isSelectingStretch, "the stretch is still picked out")
        #expect(session.steps.isEmpty)
        #expect(!session.hasChanges)
        session.move(.end, to: Self.distances[8])
        #expect(!session.picksWholeLine)
    }

    @Test("a line that ends where it began, across a pause that carried it, is offered no way back")
    func noWayBackForALineAlreadyHome() async throws {
        let context = try Fixture.modelContext()
        // The line, then carried by a pause to the far side of a valley and
        // walked on from there: no shape, as a pause that moved the walk
        // leaves none.
        var across = Self.point(10)
        across.longitude += Line.detourOffset * 5
        across.boundary = .paused
        var beyond = Self.point(9)
        beyond.longitude = across.longitude
        let carried = Self.route + [across, beyond]
        let hike = Fixture.hike(in: context, route: carried)
        let session = await visit(hike, in: context)
        #expect(session.line?.shape == nil, "precondition")
        #expect(!session.keptEndsMeet)

        await session.goOutAndBack()
        #expect(session.steps == [.outAndBack])
        #expect(!session.returnsToItsStart, "still no shape")
        #expect(session.keptEndsMeet)

        await session.goOutAndBack()
        await session.closeLoop()
        #expect(session.steps == [.outAndBack], "it is home already")
        #expect(session.line?.route.count == carried.count * 2 - 1)

        let made = await session.redraw(with: session.steps + [.outAndBack], isNewStep: true)
        #expect(!made, "a step that leaves the line as it was is not made")
        #expect(session.steps == [.outAndBack])
    }

    // MARK: The cover

    @Test("a single leg taken out is covered, though both its points are still on the line")
    func aLegTakenOutIsCovered() async throws {
        let context = try Fixture.modelContext()
        let hike = try savedHike(in: context)
        let session = await visit(hike, in: context)
        await session.beginStretch()
        session.move(.start, to: Self.distances[3])
        session.move(.end, to: Self.distances[4])

        await session.takeOutStretch()

        #expect(session.line?.route.count == Self.route.count, "precondition: no point went")
        #expect(session.staleStretches.count == 1)
        #expect(session.staleStretches.first?.map(\.latitude) == [Self.route[3].latitude, Self.route[4].latitude])
    }

    // MARK: One change at a time

    @Test("while a step is being worked out, nothing else changes the line")
    func oneChangeAtATime() async throws {
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
        let router = HeldRouter()
        let session = await visit(recorded, in: context, router: router)

        let closing = Task { await session.closeLoop() }
        await settleDelegateHop(until: "the way home is asked for") { router.isAsked }
        #expect(session.isMakingStep)
        #expect(!session.canMakeSteps)
        await session.choose(.gps, forCheck: 1)
        router.answer()
        await closing.value

        #expect(!session.isMakingStep)
        #expect(session.checks.first?.choice == .matched, "the answer given while the loop was closed is not taken")
        #expect(session.steps.count == 1, "and the loop is closed")
        #expect(session.line?.steps == session.steps)
        #expect(await session.editedLine() != nil, "a line drawn under the steps it would be saved with")
    }

    // MARK: A pause at the edge

    @Test("a stretch pulled from the line's start begins where the walk did, not where the drive to it did")
    func aPullAfterTheDrive() async throws {
        let context = try Fixture.modelContext()
        var trailhead = Self.route[0]
        trailhead.boundary = .paused
        var home = Self.point(0)
        home.latitude -= Line.spacing * 50
        home.timestamp = Line.start.addingTimeInterval(-Line.walkSeconds)
        let driven = [home, trailhead] + Self.route.dropFirst()
        let hike = Fixture.hike(in: context, route: driven)
        try context.save()
        let session = await visit(hike, in: context)
        let via = CLLocationCoordinate2D(
            latitude: Line.latitude + 1.5 * Line.spacing,
            longitude: Line.longitude + Line.detourOffset / 2
        )

        #expect(await session.reroute(0...Self.distances[3], through: via))

        let drawn = try #require(session.line?.route)
        #expect(Array(drawn.prefix(2)) == [home, trailhead], "the drive is still a pause")
        #expect(drawn.lengthMeters < Self.distances[10] + 2 * Line.spacing * 111_000, "and no walk home")
    }

    // MARK: The whole-route menu

    @Test("a loop is offered Start Loop Here, an out and back nothing of its shape, and a drag wakes neither")
    func whatTheMenuOffers() async throws {
        let context = try Fixture.modelContext()
        let loop = Fixture.hike(in: context, route: Fixture.loopRoute)
        let there = Fixture.hike(in: context, route: Fixture.outAndBackRoute)
        try context.save()

        let back = await visit(there, in: context)
        #expect(back.line?.shape == .outAndBack, "precondition")
        #expect(!back.isLoop, "begun at its far end an out and back is the same walk turned round")
        #expect(back.keptEndsMeet, "and it is home already")

        let round = await visit(loop, in: context)
        let menu = ObservationCounter {
            _ = round.isLoop
            _ = round.canStartLoopAtCut
        }
        await menu.settle()
        let drag = round.totalMeters / 20
        round.move(.start, to: drag)
        await menu.settle()
        #expect(round.canStartLoopAtCut)
        #expect(menu.count == 1)

        round.move(.start, to: drag * 2)
        round.move(.start, to: drag * 3)
        await menu.settle()
        #expect(menu.count == 1, "a handle dragged on is no news to the menu")
    }
}
