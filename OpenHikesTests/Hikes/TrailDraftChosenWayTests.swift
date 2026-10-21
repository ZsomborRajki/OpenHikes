//
//  TrailDraftChosenWayTests.swift
//  OpenHikesTests
//
//  A grey alternative, once chosen, stays chosen.
//
//  The router answers the same two stops the same way every time, so a
//  drawing reopened from its stops comes back as the router's default unless
//  something remembered that the hiker preferred the other way. These pin that
//  something across the three ways a drawing is reopened — *Edit Route*, a
//  draft restored after a relaunch, and the switch turned off and on — against
//  a router that always offers the same two ways. See ``TrailLegChoice``.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Trail draft chosen way")
struct TrailDraftChosenWayTests {
    nonisolated private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let north: Double = 47.6340
        static let middle: Double = 47.6320
        /// How far either way round a leg bows, in degrees of longitude.
        static let bow: Double = 0.002
    }

    /// Two ways between any two places, the same two every time: west of the
    /// straight line first — the router's default — and east as the
    /// alternative.
    nonisolated private struct TwoWayRouter: TrailLegRouting {
        @concurrent
        func route(_ ends: TrailLegEnds) async -> TrailLegRoute? {
            let first = TrailDraftChosenWayTests.way(along: ends, bowing: -Line.bow)
            let second = TrailDraftChosenWayTests.way(along: ends, bowing: Line.bow)
            return TrailLegRoute(
                coordinates: first.coordinates,
                distanceMeters: first.distanceMeters,
                snap: .snapped,
                alternatives: [second]
            )
        }
    }

    nonisolated private static func way(along ends: TrailLegEnds, bowing offset: Double) -> TrailLegPath {
        let middle = RouteCoordinate(
            latitude: (ends.start.latitude + ends.end.latitude) / 2,
            longitude: (ends.start.longitude + ends.end.longitude) / 2 + offset
        )
        let shape = [ends.start, middle, ends.end]
        return TrailLegPath(coordinates: shape, distanceMeters: shape.lengthMeters, travelTime: nil)
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    private static var ends: TrailLegEnds {
        TrailLegEnds(
            from: TrailWaypoint(coordinate: coordinate(Line.south)),
            to: TrailWaypoint(coordinate: coordinate(Line.north))
        )
    }

    private static var east: TrailLegPath { way(along: ends, bowing: Line.bow) }
    private static var west: TrailLegPath { way(along: ends, bowing: -Line.bow) }

    /// The two stops, south to north, with `chosen` remembered between them —
    /// a drawing as a restore hands it over, before anything is asked.
    private static func restored(choosing chosen: TrailLegPath) -> TrailDraft {
        let draft = TrailDraft()
        draft.replace(
            with: [Line.south, Line.north].map { TrailWaypoint(coordinate: coordinate($0)) },
            places: [],
            snapsToPaths: true,
            chosenLegs: [TrailLegChoice(chosen, between: ends)]
        )
        return draft
    }

    /// Whether the line's one leg has settled on a way the router gave.
    private static func settled(_ maker: TrailDraftController) -> Bool {
        maker.draft.legs.count == 1 && maker.draft.legs.allSatisfy { $0.snap == .snapped }
    }

    /// A maker with the south-to-north leg drawn, answered, and its east way
    /// chosen over the router's west one.
    private static func drawnEast(store: TrailDraftStore? = nil) async throws -> TrailDraftController {
        let maker = TrailDraftController(store: store, router: TwoWayRouter())
        maker.setEditing(true)
        maker.appendWaypoint(at: coordinate(Line.south))
        maker.appendWaypoint(at: coordinate(Line.north))
        await settleDelegateHop(until: "the leg to be answered") { settled(maker) }
        try #require(maker.draft.legs.first?.coordinates == west.coordinates, "the router's own way first")

        maker.chooseRoute(0, forLegAt: 0)
        try #require(maker.draft.legs.first?.coordinates == east.coordinates)
        return maker
    }

    // MARK: Reopening

    @Test("Edit Route reopens a saved trail on the way chosen, and saving keeps it")
    func editRouteKeepsTheChosenWay() async throws {
        let context = try Fixture.modelContext()
        let maker = try await Self.drawnEast()
        let hike = try #require(TrailDraftSave.hike(from: maker.draft, named: "Ridge", into: context).hike)
        #expect(hike.route.contains { $0.longitude > Line.longitude }, "the hike is the east way")

        let reopened = TrailDraftController(router: TwoWayRouter())
        #expect(reopened.edit(hike))
        reopened.setEditing(true)
        await settleDelegateHop(until: "the reopened leg to be answered") { Self.settled(reopened) }

        let leg = try #require(reopened.draft.legs.first)
        #expect(leg.coordinates == Self.east.coordinates, "not the router's default")
        #expect(leg.alternatives.map(\.coordinates) == [Self.west.coordinates], "which is offered instead")

        let saved = try #require(
            TrailDraftSave.update(hike, from: reopened.draft, openedWith: [], into: context).hike
        )
        #expect(saved.route.contains { $0.longitude > Line.longitude })
        #expect(!saved.route.contains { $0.longitude < Line.longitude }, "an unchanged edit does not swap ways")
    }

    @Test("a draft restored after a relaunch comes back on the way chosen")
    func aRestoredDraftKeepsTheChosenWay() async throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        let maker = try await Self.drawnEast(store: store)
        maker.setEditing(false)

        #expect(store.load().chosenLegs.map(\.coordinates) == [Self.east.coordinates], "written down on the tap")

        let relaunched = TrailDraftController(store: store, router: TwoWayRouter())
        relaunched.setEditing(true)
        await settleDelegateHop(until: "the restored leg to be answered") { Self.settled(relaunched) }

        #expect(relaunched.draft.legs.first?.coordinates == Self.east.coordinates)
    }

    @Test("turning path-following off and on again keeps the way chosen")
    func theSwitchKeepsTheChosenWay() async throws {
        let maker = try await Self.drawnEast()

        maker.setSnapsToPaths(false)
        maker.setSnapsToPaths(true)
        await settleDelegateHop(until: "the leg to be answered again") { Self.settled(maker) }

        #expect(maker.draft.legs.first?.coordinates == Self.east.coordinates)
    }

    // MARK: Laying a choice over an answer

    /// A choice the router no longer offers is still the hiker's: it is drawn,
    /// and the router's answer goes on offer beside it.
    @Test("a chosen way the router stopped offering is drawn, with the router's way offered")
    func aWayNoLongerOfferedIsKept() {
        let further = Self.way(along: Self.ends, bowing: 3 * Line.bow)
        let draft = Self.restored(choosing: further)
        let answer = TrailLegRoute(
            coordinates: Self.west.coordinates,
            distanceMeters: Self.west.distanceMeters,
            snap: .snapped
        )
        draft.beginRouting([Self.ends])
        draft.apply(answer, to: Self.ends)

        let leg = draft.legs.first
        #expect(leg?.coordinates == further.coordinates)
        #expect(leg?.alternatives.map(\.coordinates) == [Self.west.coordinates])
    }

    @Test(
        "a remembered way keeps its own access warning when the router offers a different path",
        arguments: [true, false]
    )
    func aRememberedWayKeepsItsAccessWarning(hasUncheckedAccess: Bool) throws {
        let draft = TrailDraft()
        draft.replace(
            with: [Line.south, Line.north].map { TrailWaypoint(coordinate: Self.coordinate($0)) },
            places: [],
            snapsToPaths: true
        )
        let chosenSnap: TrailLegSnap = hasUncheckedAccess ? .unmapped(.endpointOffNetwork) : .snapped
        draft.beginRouting([Self.ends])
        draft.apply(
            TrailLegRoute(
                coordinates: Self.west.coordinates,
                distanceMeters: Self.west.distanceMeters,
                snap: chosenSnap,
                alternatives: [Self.east]
            ),
            to: Self.ends
        )
        draft.chooseAlternative(0, forLegAt: 0)
        try #require(draft.legs.first?.snap == chosenSnap)

        let saved = try JSONEncoder().encode(DrawnRoute(draft))
        let drawn = try JSONDecoder().decode(DrawnRoute.self, from: saved)
        let reopened = TrailDraft()
        reopened.replace(
            with: drawn.trailWaypoints,
            places: [],
            snapsToPaths: drawn.snapsToPaths,
            chosenLegs: drawn.chosenLegs
        )
        reopened.beginRouting([Self.ends])
        reopened.apply(
            TrailLegRoute(
                coordinates: Self.west.coordinates,
                distanceMeters: Self.west.distanceMeters,
                snap: hasUncheckedAccess ? .snapped : .unmapped(.endpointOffNetwork)
            ),
            to: Self.ends
        )

        #expect(reopened.legs.first?.coordinates == Self.east.coordinates)
        #expect(reopened.legs.first?.snap == chosenSnap, "the new answer describes a different path")
    }

    /// A refusal says the leg could not be asked about; the choice is not an
    /// answer to that, and waits for the next one.
    @Test("a refusal is drawn as one, and the choice waits for the next answer")
    func aRefusalLeavesTheChoiceWaiting() {
        let draft = Self.restored(choosing: Self.east)
        draft.beginRouting([Self.ends])
        draft.apply(.straight(along: Self.ends, .refused(.busy)), to: Self.ends)

        #expect(draft.legs.first?.coordinates == Self.ends.straightCoordinates)
        #expect(draft.chosenLegs.map(\.coordinates) == [Self.east.coordinates])
    }

    @Test("a new travel mode forgets the ways chosen for the old one")
    func aNewModeForgetsTheChoice() {
        let draft = Self.restored(choosing: Self.east)
        draft.setTravelMode(.walking)
        #expect(draft.chosenLegs.isEmpty)
    }

    /// Only the legs the line has are written down: a choice for a leg a
    /// stop has since been put into is about two places no longer adjacent.
    @Test("only the legs the line still has carry their choice to disk")
    func onlyCurrentLegsAreWritten() {
        let draft = Self.restored(choosing: Self.east)
        draft.append(Self.coordinate(Line.middle))
        #expect(draft.chosenLegs.count == 1, "south to north is still a leg")

        draft.remove(atOffsets: IndexSet([1]))
        #expect(draft.chosenLegs.isEmpty)
    }
}
