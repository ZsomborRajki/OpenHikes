//
//  TrailStopTests.swift
//  OpenHikesTests
//
//  What a point is to the route it is in, and what it is called.
//
//  The two facts the maker's list was rebuilt around. The role is derived from
//  a point's place in the line and is stored nowhere, so every claim about it
//  is a claim about the list; the name is stored, and the interesting claims
//  are about the three things that are allowed to *unset* it.
//
//  What is asserted elsewhere: `TrailDraftStoreTests` that a name survives a
//  relaunch, `TrailStopNamerTests` the queue that produces one,
//  `TrailStopNameTests` which of MapKit's several words is chosen, and
//  `TrailMakerUITests` that a row is tappable at all with the list permanently
//  in edit mode — which is the one claim none of these can make.
//

import CoreLocation
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

    /// A description is not an edit, so it must not be offered back as one —
    /// and it must not push the tap that drew the point a step further away.
    @Test("a description takes no step of undo")
    func aDescriptionIsNotAnEdit() {
        let draft = Self.drawn([Ridge.south, Ridge.north])
        let id = draft.waypoints[1].id

        draft.describe(waypointWith: id, as: "Gellért-hegy")
        draft.undo()

        // One step back is the second *point*, not the name it was given: the
        // description sat outside the history entirely, so undoing reaches past
        // it to the tap that drew the point.
        #expect(draft.waypoints.count == 1)
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
        #expect(draft.canUndo, "the hiker chose this, so it is a step")
    }

    /// A press held on a pin and released without travelling is not an edit,
    /// and since a move now clears the name, calling it one would also silently
    /// rename the row it was held on.
    @Test("a press that went nowhere keeps the name and takes no step")
    func aDragThatDidNotMoveChangesNothing() {
        let draft = TrailDraft()
        draft.append(Self.coordinate(Ridge.south), named: "Lurdy Ház")
        draft.append(Self.coordinate(Ridge.north))
        let stepsBefore = draft.canUndo

        #expect(draft.beginDrag(ofWaypointAt: 0))
        #expect(!draft.endDrag(), "nothing moved, so nothing was edited")

        #expect(draft.name(ofWaypointAt: 0) == "Lurdy Ház")
        #expect(draft.canUndo == stepsBefore)
    }

    /// A loop ends at the place it began at, so the two rows say the same
    /// thing rather than one of them reading "Destination" beside it.
    @Test("closing the loop carries the start's name to the end")
    func closingTheLoopCarriesTheName() {
        let draft = TrailDraft()
        draft.append(Self.coordinate(Ridge.south), named: "Lurdy Ház")
        draft.append(Self.coordinate(Ridge.north))

        draft.closeTheLoop()

        #expect(draft.waypoints.count == 3)
        #expect(draft.name(ofWaypointAt: 2) == "Lurdy Ház")
        #expect(draft.role(ofWaypointAt: 2) == .end)
    }
}
