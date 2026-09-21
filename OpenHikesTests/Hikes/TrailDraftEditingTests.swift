//
//  TrailDraftEditingTests.swift
//  OpenHikesTests
//
//  The six things Phase 3 lets a hiker do to a line that is already drawn.
//
//  Each of them is arithmetic over a list, and every one of them is a gesture
//  that gets the list wrong in a way nobody sees until they save: a reorder
//  that lands one row short, a reverse that leaves the legs pointing the way
//  they were, a *Close the Loop* that stacks a second zero-length leg onto a
//  loop that was already closed. What is asserted here is the list *and* the
//  two figures that come out of it, because the header, the rows and the
//  saved hike all read the second — see ``TrailDraftTests``.
//
//  ``TrailDraftHistoryTests`` owns undo and redo, and
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

    /// The same line, with nothing behind it to undo.
    ///
    /// Drawing a line records a step per point, so a draft built by tapping
    /// can always be undone — which makes it useless for asserting that an
    /// operation recorded *no* step. A restored draft has no history by
    /// design, so ``TrailDraft/canUndo`` on one is exactly the question "did
    /// what I just did count as an edit".
    private static func settledDraft(_ latitudes: [Double]) -> TrailDraft {
        let draft = TrailDraft()
        draft.replace(
            with: latitudes.map { TrailWaypoint(coordinate: coordinate($0)) },
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
        #expect(!draft.canUndo, "a move that moved nothing is not a step")
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
    @Test("deleting nothing is not a step")
    func deletingNothing() {
        let draft = Self.settledDraft(Line.all)

        draft.remove(atOffsets: IndexSet([9]))

        #expect(draft.waypoints.count == 4)
        #expect(!draft.canUndo)
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

    @Test("a reorder that changes nothing is not a step")
    func reorderingNowhere() {
        let draft = Self.settledDraft(Line.all)

        draft.moveWaypoints(fromOffsets: IndexSet([1]), toOffset: 1)

        #expect(Self.latitudes(of: draft) == Line.all)
        #expect(!draft.canUndo)
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

    // MARK: Reversing

    @Test("reversing turns the points round")
    func reversing() {
        let draft = Self.draft(Line.all)

        draft.reverse()

        #expect(Self.latitudes(of: draft) == Line.all.reversed())
    }

    /// The claim that makes reversing free: every leg already has its shape,
    /// and a walking path between two places is the same path either way — so
    /// the legs are turned round rather than thrown away and asked for again.
    @Test("reversing keeps every leg's shape, turned round")
    func reversingKeepsTheShapes() throws {
        let draft = Self.draft([Line.first, Line.second])
        let ends = try #require(draft.legs.first).ends
        // A leg that has been given a shape, as the router would have —
        // marked as asked about first, because an answer is only taken by a
        // leg that is waiting for one.
        draft.beginRouting([ends])
        draft.apply(
            TrailLegRoute(
                coordinates: [
                    ends.start,
                    RouteCoordinate(latitude: Line.elsewhere, longitude: Line.longitude),
                    ends.end,
                ],
                distanceMeters: 1234,
                snap: .snapped
            ),
            to: ends
        )

        draft.reverse()

        let reversed = try #require(draft.legs.first)
        #expect(reversed.snap == .snapped, "the answer survives the reversal")
        #expect(reversed.ends == ends.flipped)
        let detour = RouteCoordinate(latitude: Line.elsewhere, longitude: Line.longitude)
        #expect(reversed.coordinates == [ends.end, detour, ends.start])
        #expect(reversed.distanceMeters == 1234)
    }

    @Test("reversing one point does nothing")
    func reversingOnePoint() {
        let draft = Self.settledDraft([Line.first])

        draft.reverse()

        #expect(!draft.canUndo)
    }

    // MARK: Closing the loop

    @Test("closing the loop adds a point back at the start")
    func closingTheLoop() {
        let draft = Self.draft([Line.first, Line.second, Line.third])

        draft.closeTheLoop()

        #expect(Self.latitudes(of: draft) == [Line.first, Line.second, Line.third, Line.first])
        #expect(draft.legs.count == 3)
    }

    /// Two points at the same place are still two points — see
    /// ``TrailDraftTests`` — so a loop closed twice would be a trail with a
    /// zero-length leg on the end and a row nobody can tell from the first.
    @Test("a loop that is already closed cannot be closed again")
    func closingAClosedLoop() {
        let draft = Self.draft([Line.first, Line.second, Line.third])
        draft.closeTheLoop()

        #expect(!draft.canCloseTheLoop)
        draft.closeTheLoop()
        #expect(draft.waypoints.count == 4)
    }

    @Test("a single point is not a loop")
    func onePointIsNotALoop() {
        let draft = Self.draft([Line.first])

        #expect(!draft.canCloseTheLoop)
        draft.closeTheLoop()
        #expect(draft.waypoints.count == 1)
    }

    // MARK: Clearing

    /// *Clear* empties the drawing and leaves the maker open, which is what
    /// makes it undoable — unlike ``TrailDraft/clear()``, which is the drawing
    /// ending.
    @Test("clearing the drawing empties it and can be undone")
    func clearingTheDrawing() {
        let draft = Self.draft(Line.all)

        draft.clearDrawing()

        #expect(draft.isEmpty)
        #expect(draft.canUndo)
        draft.undo()
        #expect(Self.latitudes(of: draft) == Line.all)
    }

    @Test("throwing the draft away leaves nothing to undo")
    func clearingTheDraft() {
        let draft = Self.draft(Line.all)

        draft.clear()

        #expect(draft.isEmpty)
        #expect(!draft.canUndo, "the drawing ended; there is nothing to come back to")
    }
}
