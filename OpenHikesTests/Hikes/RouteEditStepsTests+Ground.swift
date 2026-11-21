//
//  RouteEditStepsTests+Ground.swift
//  OpenHikesTests
//
//  A step is made on the ground it was worked out on, or not at all: a path
//  that comes back after a handle moved is dropped, a step that would change
//  nothing is not made, and the gray cover hides every stretch of the hike's
//  own line the new one no longer draws the same way.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
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
}
