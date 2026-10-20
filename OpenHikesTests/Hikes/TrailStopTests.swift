//
//  TrailStopTests.swift
//  OpenHikesTests
//
//  What a point is to the route it is in, and what it is called.
//
//  The two facts the maker's list was rebuilt around. The role is derived from
//  a point's place in the line and is stored nowhere, so every claim about it
//  is a claim about the list; the name is stored, and the interesting claims
//  are about the three things that are allowed to *unset* it. Then the line a
//  stop's row, pin and card each print under its heading, which is what keeps
//  two stops apart when their names are the same.
//
//  What is asserted elsewhere: `TrailDraftStoreTests` that a name survives a
//  relaunch, `TrailStopNamerTests` the queue that produces one,
//  `TrailStopNameTests` which of MapKit's several words is chosen, and
//  `TrailMakerUITests` that a row is tappable at all with the list permanently
//  in edit mode — which is the one claim none of these can make.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail stops")
struct TrailStopTests {
    private enum Ridge {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let middle: Double = 47.6320
        static let north: Double = 47.6340
        static let far: Double = 47.6400
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Ridge.longitude)
    }

    private static func drawn(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes { draft.append(coordinate(latitude)) }
        return draft
    }

    // MARK: - Roles

    @Test("a lone point is a start and nothing else")
    func onePointIsAStart() {
        let draft = Self.drawn([Ridge.south])
        #expect(draft.role(ofWaypointAt: 0) == .start)
    }

    @Test("two points are a start and a destination, with nothing between")
    func twoPointsAreTheTwoEnds() {
        let draft = Self.drawn([Ridge.south, Ridge.north])
        #expect(draft.role(ofWaypointAt: 0) == .start)
        #expect(draft.role(ofWaypointAt: 1) == .end)
    }

    @Test("the stops between are counted from one, as a hiker reads them")
    func middlePointsAreNumberedStops() {
        let draft = Self.drawn([Ridge.south, Ridge.middle, Ridge.north, Ridge.far])
        #expect(draft.role(ofWaypointAt: 1) == .stop(number: 1))
        #expect(draft.role(ofWaypointAt: 2) == .stop(number: 2))
    }

    /// The whole reason the role is derived rather than stored: dragging the
    /// last row to the top makes it the start, with nothing written anywhere.
    @Test("reordering changes what each point is, with nothing stored")
    func reorderingChangesTheRoles() {
        let draft = Self.drawn([Ridge.south, Ridge.middle, Ridge.north])
        let wasLast = draft.waypoints[2].id

        draft.moveWaypoints(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(draft.waypoints[0].id == wasLast)
        #expect(draft.role(ofWaypointAt: 0) == .start)
        #expect(draft.role(ofWaypointAt: 2) == .end)
    }

    // MARK: - Names

    @Test("a point put down by a tap is not named")
    func aTappedPointHasNoName() {
        let draft = Self.drawn([Ridge.south])
        #expect(draft.name(ofWaypointAt: 0).isEmpty)
    }

    @Test("a point picked out of the search arrives named")
    func aSearchedPointKeepsItsName() {
        let draft = TrailDraft()
        draft.append(Self.coordinate(Ridge.south), named: "Lurdy Ház")
        #expect(draft.name(ofWaypointAt: 0) == "Lurdy Ház")
    }

    /// The description ``TrailStopNamer`` produces, matched by identity rather
    /// than by row — the hiker can have reordered since it was asked for.
    @Test("a name that lands late finds its own point, wherever it has moved to")
    func aLateNameFollowsItsPoint() {
        let draft = Self.drawn([Ridge.south, Ridge.middle, Ridge.north])
        let asked = draft.waypoints[2].id

        draft.moveWaypoints(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        draft.describe(waypointWith: asked, as: "Gellért-hegy")

        #expect(draft.name(ofWaypointAt: 0) == "Gellért-hegy")
        #expect(draft.name(ofWaypointAt: 1).isEmpty)
    }

    @Test("a description never overwrites a name the hiker chose")
    func aDescriptionYieldsToAChoice() {
        let draft = TrailDraft()
        draft.append(Self.coordinate(Ridge.south), named: "Lurdy Ház")
        let id = draft.waypoints[0].id

        draft.describe(waypointWith: id, as: "Könyves Kálmán körút")

        #expect(draft.name(ofWaypointAt: 0) == "Lurdy Ház")
    }

    /// A description is not a change to the line: nothing geometric moves, so
    /// no leg has anything to be asked about again.
    @Test("a description leaves the line alone")
    func aDescriptionIsNotAnEdit() {
        let draft = Self.drawn([Ridge.south, Ridge.north])
        let id = draft.waypoints[1].id
        let legs = draft.legs

        draft.describe(waypointWith: id, as: "Gellért-hegy")

        #expect(draft.name(ofWaypointAt: 1) == "Gellért-hegy")
        #expect(draft.legs == legs)
    }

    /// The one thing on a row that could be false: a point called "Lurdy Ház"
    /// that has been dragged half a kilometre up the hill.
    @Test("moving a point throws its name away")
    func movingForgetsTheName() {
        let draft = TrailDraft()
        draft.append(Self.coordinate(Ridge.south), named: "Lurdy Ház")

        draft.move(waypointAt: 0, to: Self.coordinate(Ridge.far))

        #expect(draft.name(ofWaypointAt: 0).isEmpty)
    }

    @Test("placing a point at a named spot writes both at once")
    func placingWritesNameAndCoordinate() {
        let draft = Self.drawn([Ridge.south, Ridge.north])

        draft.place(
            waypointAt: 1,
            at: Self.coordinate(Ridge.far),
            named: "Kehlsteinhaus"
        )

        #expect(draft.name(ofWaypointAt: 1) == "Kehlsteinhaus")
        #expect(draft.waypoints[1].latitude == Ridge.far)
    }

    /// A press held on a pin and released without travelling is not an edit,
    /// and since a move now clears the name, calling it one would also silently
    /// rename the row it was held on.
    @Test("a press that went nowhere keeps the name")
    func aDragThatDidNotMoveChangesNothing() {
        let draft = TrailDraft()
        draft.append(Self.coordinate(Ridge.south), named: "Lurdy Ház")
        draft.append(Self.coordinate(Ridge.north))

        #expect(draft.beginDrag(ofWaypointAt: 0))
        #expect(!draft.endDrag(), "nothing moved, so nothing was edited")

        #expect(draft.name(ofWaypointAt: 0) == "Lurdy Ház")
    }

    // MARK: - The line under a heading

    /// The line each of the first `count` stops prints under its heading.
    private static func details(_ draft: TrailDraft, count: Int) -> [String?] {
        (0..<count).map { index in
            draft.role(ofWaypointAt: index).detail(
                isNamed: !draft.name(ofWaypointAt: index).isEmpty,
                along: draft.distanceAlongLine(toWaypointAt: index)
            )
        }
    }

    private static func length(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    /// The route this line was added for: MapKit called two pins in one
    /// forest by their postcode, and nothing else on either row said which
    /// of the pins it was.
    @Test("two stops with the same name are still told apart")
    func sameNamesAreToldApart() {
        let draft = Self.drawn([Ridge.south, Ridge.middle, Ridge.north])
        draft.describe(waypointWith: draft.waypoints[0].id, as: "4810 Gmunden")
        draft.describe(waypointWith: draft.waypoints[1].id, as: "4810 Gmunden")

        let lines = Self.details(draft, count: 2)

        #expect(lines[0] != lines[1])
        #expect(lines[0] == "Start")
        #expect(lines[1]?.hasPrefix("Stop 1") == true, "the role a name hides is what ties a row to pin 1")
    }

    @Test("a named stop keeps its role and says how far along it sits")
    func aNamedStopSaysItsRoleAndDistance() throws {
        let line = try #require(TrailStopRole.stop(number: 1).detail(isNamed: true, along: 1900))
        #expect(line.hasPrefix("Stop 1 · "))
        #expect(line.contains(Self.length(1900)))
    }

    /// Its heading is already the role, so the line does not say it twice.
    @Test("an unnamed stop's line is how far along it sits, alone")
    func anUnnamedStopSaysItsDistance() throws {
        let line = try #require(TrailStopRole.stop(number: 2).detail(isNamed: false, along: 1250))
        #expect(line.contains(Self.length(1250)))
        #expect(!line.contains("Stop 2"))
    }

    /// The start, and a lone destination with the start still open: neither
    /// is anywhere along a route yet, and "0 m along the route" is a line
    /// spent on nothing.
    @Test("nothing is said of a distance that is nothing", arguments: [TrailStopRole.start, .end])
    func noDistanceWhereThereIsNone(_ role: TrailStopRole) {
        #expect(role.detail(isNamed: false, along: 0) == nil)
        #expect(role.detail(isNamed: true, along: 0) == role.title)
    }

    /// The card a tap on a stop's pin opens is headed like its row, so it says
    /// the same thing under the heading too.
    @Test("a stop's card says what its row says under the same heading")
    func theCardAgreesWithTheRow() throws {
        let draft = Self.drawn([Ridge.south, Ridge.middle, Ridge.north])
        draft.describe(waypointWith: draft.waypoints[1].id, as: "Gellért-hegy")
        let lines = Self.details(draft, count: 3)

        for (index, line) in lines.enumerated() {
            let card = try #require(TrailPlaceCard(.stop(draft.waypoints[index].id), in: draft, droppedPin: nil))
            #expect(card.subtitle == line)
        }
        #expect(lines[0] == nil, "an unnamed start's card has nothing under its heading")
    }
}
