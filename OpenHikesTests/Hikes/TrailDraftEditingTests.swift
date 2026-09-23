//
//  TrailDraftEditingTests.swift
//  OpenHikesTests
//
//  The things a hiker can do to a line that is already drawn.
//
//  Each of them is arithmetic over a list, and every one of them is a gesture
//  that gets the list wrong in a way nobody sees until they save: a reorder
//  that lands one row short, a delete that does not rejoin what is left. What
//  is asserted here is the list *and* the two figures that come out of it,
//  because the header, the rows and the saved hike all read the second — see
//  ``TrailDraftTests``.
//
//  ``TrailDraftRoutingTests`` owns which of these operations costs a question.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail draft editing")
struct TrailDraftEditingTests {
    /// Four points on one line of longitude, evenly spaced, so a distance is a
    /// degree of latitude and nothing else and the arithmetic of a reorder is
    /// readable in the numbers.
    private enum Line {
        static let longitude: Double = 12.8317
        static let first: Double = 47.7100
        static let second: Double = 47.7120
        static let third: Double = 47.7140
        static let fourth: Double = 47.7160
        static let elsewhere: Double = 47.7300
        static let all: [Double] = [first, second, third, fourth]
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    private static func draft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        for latitude in latitudes { draft.append(coordinate(latitude)) }
        return draft
    }

    /// The same line, restored rather than tapped in.
    private static func settledDraft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        draft.replace(
            with: latitudes.map { TrailWaypoint(coordinate: coordinate($0)) },
            places: [],
            snapsToPaths: true
        )
        return draft
    }

    /// What the line looks like, as latitudes, which is the readable shape of
    /// every assertion below.
    private static func latitudes(of draft: TrailDraft) -> [Double] {
        draft.waypoints.map(\.latitude)
    }

    // MARK: Moving a point

    @Test("moving a point moves it and remeasures the line")
    func movingAPoint() {
        let draft = Self.draft([Line.first, Line.second])
        let before = draft.distanceMeters

        draft.move(waypointAt: 1, to: Self.coordinate(Line.fourth))

        #expect(Self.latitudes(of: draft) == [Line.first, Line.fourth])
        #expect(draft.distanceMeters > before)
    }

    /// The identity is what a row is keyed on and what a reorder moves, so it
    /// has to survive the point being moved on the ground — otherwise a drag
    /// would look to the list like a delete and an insert.
    @Test("a moved point keeps its identity")
    func movingKeepsTheIdentity() throws {
        let draft = Self.draft([Line.first, Line.second])
        let id = try #require(draft.waypoints.last).id

        draft.move(waypointAt: 1, to: Self.coordinate(Line.fourth))

        #expect(draft.waypoints.last?.id == id)
    }

    @Test("moving a point that isn't there changes nothing")
    func movingOutOfRange() {
        let draft = Self.settledDraft([Line.first, Line.second])

        draft.move(waypointAt: 7, to: Self.coordinate(Line.fourth))

        #expect(Self.latitudes(of: draft) == [Line.first, Line.second])
    }

    // MARK: Inserting into a leg

    /// The operation a tap on a drawn leg means: leg *n* runs from point *n*
    /// to point *n + 1*, so the new point lands between them and the leg
    /// becomes two.
    @Test("inserting into a leg puts the point between that leg's two ends")
    func insertingIntoALeg() {
        let draft = Self.draft([Line.first, Line.fourth])

        draft.insert(Self.coordinate(Line.second), intoLegAt: 0)

        #expect(Self.latitudes(of: draft) == [Line.first, Line.second, Line.fourth])
        #expect(draft.legs.count == 2)
    }

    @Test("inserting into the second leg of three points lands in the right place")
    func insertingIntoTheSecondLeg() {
        let draft = Self.draft([Line.first, Line.second, Line.fourth])

        draft.insert(Self.coordinate(Line.third), intoLegAt: 1)

        #expect(Self.latitudes(of: draft) == Line.all)
    }

    @Test("inserting into a leg that isn't there changes nothing")
    func insertingIntoNoLeg() {
        let draft = Self.draft([Line.first, Line.second])

        draft.insert(Self.coordinate(Line.third), intoLegAt: 4)

        #expect(draft.waypoints.count == 2)
    }

    // MARK: Deleting

    @Test("deleting takes the points out and rejoins what is left")
    func deleting() {
        let draft = Self.draft(Line.all)

        draft.remove(atOffsets: IndexSet([1]))

        #expect(Self.latitudes(of: draft) == [Line.first, Line.third, Line.fourth])
        #expect(draft.legs.count == 2)
    }

    @Test("deleting several at once takes all of them")
    func deletingSeveral() {
        let draft = Self.draft(Line.all)

        draft.remove(atOffsets: IndexSet([0, 2]))

        #expect(Self.latitudes(of: draft) == [Line.second, Line.fourth])
    }

    /// The list can hand over offsets for rows that have already gone, and a
    /// delete that matched none of them is not an edit.
    @Test("deleting nothing changes nothing")
    func deletingNothing() {
        let draft = Self.settledDraft(Line.all)

        draft.remove(atOffsets: IndexSet([9]))

        #expect(draft.waypoints.count == 4)
    }

    // MARK: Reordering

    /// SwiftUI's own `onMove` semantics: the destination is an offset into the
    /// list *as it stands*, so a row dragged downwards lands after the rows
    /// still above it rather than one place short. This is the case that gets
    /// it wrong when the adjustment is left out.
    @Test("a row dragged downwards lands where it was dropped")
    func reorderingDownwards() {
        let draft = Self.draft(Line.all)

        draft.moveWaypoints(fromOffsets: IndexSet([0]), toOffset: 3)

        #expect(Self.latitudes(of: draft) == [Line.second, Line.third, Line.first, Line.fourth])
    }

    @Test("a row dragged upwards lands where it was dropped")
    func reorderingUpwards() {
        let draft = Self.draft(Line.all)

        draft.moveWaypoints(fromOffsets: IndexSet([3]), toOffset: 1)

        #expect(Self.latitudes(of: draft) == [Line.first, Line.fourth, Line.second, Line.third])
    }

    @Test("a reorder that goes nowhere changes nothing")
    func reorderingNowhere() {
        let draft = Self.settledDraft(Line.all)

        draft.moveWaypoints(fromOffsets: IndexSet([1]), toOffset: 1)

        #expect(Self.latitudes(of: draft) == Line.all)
    }

    /// The length is read off the legs, and a reorder changes which legs there
    /// are — so a list that reordered without remeasuring would leave the
    /// header and the rows describing the trail that was there before.
    @Test("a reorder remeasures the line")
    func reorderingRemeasures() {
        let draft = Self.draft([Line.first, Line.second, Line.elsewhere])
        let straightThrough = draft.distanceMeters

        draft.moveWaypoints(fromOffsets: IndexSet([2]), toOffset: 1)

        #expect(draft.distanceMeters > straightThrough, "the detour is longer than the line")
        #expect(draft.distanceAlongLine(toWaypointAt: 2) == draft.distanceMeters)
    }

    // MARK: Throwing it away

    @Test("throwing the draft away empties it")
    func clearingTheDraft() {
        let draft = Self.draft(Line.all)

        draft.clear()

        #expect(draft.isEmpty)
        #expect(draft.legs.isEmpty)
        #expect(draft.slots == [.open(.start), .open(.end)])
    }
}
